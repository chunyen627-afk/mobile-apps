"""Bluetooth thermometer gateway: hears BLE thermometers next to this PC and serves their latest
readings as JSON on a private (ZeroTier) address, for the toolbox app's thermometer tab.

Readings come from plain (unencrypted) advertisements, so any number of thermometers can be read
at once without connecting to them:
  * BTHome v2 (service data 0xFCD2), the default of the pvvx custom firmware;
  * pvvx custom format and atc1441 format (service data 0x181A).
A thermometer still on Xiaomi's stock firmware (encrypted advertisements) can be listed in the
config with "gatt": true; it is then connected to every gatt_poll_seconds and read directly
(LYWSD03MMC stock firmware only).

Every 5 minutes each thermometer heard in those 5 minutes is sampled into a local SQLite file
(thermo-history.sqlite, kept history_days, default 90) for the app's history charts.

HTTP (read-only): GET /sensors, GET /history?id=<address>&range=day|week|month and GET /health,
answered only to clients inside allowed_networks; the server binds one specific address, never
0.0.0.0.

    python thermo_gateway.py [--config thermo-gateway.json]
    python thermo_gateway.py --fake fixtures/fake-sensors.json --bind 127.0.0.1 --port 8795

The fake mode serves fixture readings without Bluetooth (used by the simulator UI tests).
"""

import argparse
import ipaddress
import json
import logging
import math
import sqlite3
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from logging.handlers import RotatingFileHandler
from pathlib import Path
from urllib.parse import parse_qs

ROOT = Path(__file__).resolve().parent
API_VERSION = 1
UUID_BTHOME = "0000fcd2-0000-1000-8000-00805f9b34fb"
UUID_ENV = "0000181a-0000-1000-8000-00805f9b34fb"
CHAR_MI_TEMP = "ebe0ccc1-7a0a-4b0c-8a1a-6ff2997da3a6"

# BTHome v2 object id -> payload length in bytes. Parsing stops at an id not listed here, since
# its length is unknown; the thermometer objects come first in pvvx's packets.
BTHOME_SIZES = {
    0x00: 1, 0x01: 1, 0x02: 2, 0x03: 2, 0x04: 3, 0x05: 3, 0x06: 2, 0x07: 2, 0x08: 2, 0x09: 1,
    0x0A: 3, 0x0B: 3, 0x0C: 2, 0x0D: 2, 0x0E: 2, 0x0F: 1, 0x10: 1, 0x11: 1, 0x12: 2, 0x13: 2,
    0x14: 2, 0x15: 1, 0x16: 1, 0x17: 1, 0x18: 1, 0x19: 1, 0x1A: 1, 0x1B: 1, 0x1C: 1, 0x1D: 1,
    0x1E: 1, 0x1F: 1, 0x20: 1, 0x21: 1, 0x22: 1, 0x23: 1, 0x24: 1, 0x25: 1, 0x26: 1, 0x27: 1,
    0x28: 1, 0x29: 1, 0x2A: 1, 0x2B: 1, 0x2C: 1, 0x2D: 1, 0x2E: 1, 0x2F: 1, 0x3A: 1, 0x3C: 2,
    0x3D: 2, 0x3E: 4, 0x3F: 2, 0x40: 2, 0x41: 2, 0x42: 3, 0x43: 2, 0x44: 2, 0x45: 2, 0x46: 1,
    0x47: 2, 0x48: 2, 0x49: 2, 0x4A: 2, 0x4B: 3, 0x4C: 4, 0x4D: 4, 0x4E: 4, 0x4F: 4, 0x50: 4,
    0x51: 2, 0x52: 2, 0x5A: 1, 0x5B: 1, 0x5C: 1, 0x5D: 1, 0x5E: 1, 0x60: 1,
}


def battery_from_voltage(mv):
    """Battery percent from a CR2032's voltage, as the pvvx firmware estimates it."""
    if mv is None:
        return None
    return max(0, min(100, round((mv - 2200) / 9)))


def decode_bthome(data: bytes):
    """BTHome v2 service data (without the UUID). None if encrypted, not v2 or malformed."""
    if len(data) < 2:
        return None
    info = data[0]
    if info & 0x01 or (info >> 5) != 2:  # encrypted, or not version 2
        return None
    out = {"format": "bthome"}
    i = 1
    while i < len(data):
        oid = data[i]
        size = BTHOME_SIZES.get(oid)
        if size is None or i + 1 + size > len(data):
            break
        raw = data[i + 1:i + 1 + size]
        if oid == 0x01:
            out["battery"] = raw[0]
        elif oid == 0x02:
            out["temperature"] = struct.unpack("<h", raw)[0] / 100
        elif oid == 0x45:
            out["temperature"] = struct.unpack("<h", raw)[0] / 10
        elif oid == 0x03:
            out["humidity"] = struct.unpack("<H", raw)[0] / 100
        elif oid == 0x2E:
            out["humidity"] = float(raw[0])
        elif oid == 0x0C:
            out["voltage"] = struct.unpack("<H", raw)[0] / 1000
        i += 1 + size
    return out if len(out) > 1 else None


def decode_env(data: bytes):
    """Service data 0x181A: pvvx custom (15 bytes) or atc1441 (13 bytes); other lengths are
    the encrypted variants and are skipped."""
    if len(data) == 15:
        temp, hum, mv, batt = struct.unpack("<hHHB", data[6:13])
        return {"format": "pvvx", "temperature": temp / 100, "humidity": hum / 100,
                "voltage": mv / 1000, "battery": batt}
    if len(data) == 13:
        temp, hum, batt, mv = struct.unpack(">hBBH", data[6:12])
        return {"format": "atc1441", "temperature": temp / 10, "humidity": float(hum),
                "voltage": mv / 1000, "battery": batt}
    return None


def decode_service_data(service_data):
    """{uuid: bytes} from one advertisement -> reading dict or None."""
    for uuid, data in service_data.items():
        uuid = uuid.lower()
        if uuid == UUID_BTHOME:
            reading = decode_bthome(bytes(data))
        elif uuid == UUID_ENV:
            reading = decode_env(bytes(data))
        else:
            continue
        if reading:
            return reading
    return None


def normalize_mac(mac):
    return mac.strip().upper().replace("-", ":")


class Store:
    """Latest reading per thermometer. BTHome packets alternate their contents (pvvx sends
    temperature/humidity/battery in one and voltage in another), so values merge."""

    FIELDS = ("temperature", "humidity", "battery", "voltage")

    def __init__(self, sensors=(), discover=True, state_path=None, clock=time.time):
        self.lock = threading.Lock()
        self.clock = clock
        self.discover = discover
        self.state_path = state_path
        self.configured = {normalize_mac(s["mac"]): s for s in sensors}
        self.items = {}
        for mac, cfg in self.configured.items():
            self.items[mac] = {"id": mac, "name": cfg.get("name") or mac, "advertised_name": None}
        if state_path and Path(state_path).exists():
            try:
                saved = json.loads(Path(state_path).read_text(encoding="utf-8"))
                for item in saved.get("sensors", []):
                    mac = normalize_mac(item["id"])
                    if mac in self.items or discover:
                        merged = {**item, "id": mac}
                        if mac in self.configured:  # the config's name wins over the saved one
                            merged["name"] = self.items[mac]["name"]
                        self.items[mac] = merged
            except (ValueError, KeyError, OSError):
                logging.exception("Ignoring an unreadable state file")

    def accepts(self, mac):
        return self.discover or normalize_mac(mac) in self.configured

    def update(self, mac, reading, rssi=None, advertised_name=None):
        mac = normalize_mac(mac)
        if not self.accepts(mac):
            return False
        with self.lock:
            item = self.items.setdefault(mac, {"id": mac, "name": advertised_name or mac, "advertised_name": None})
            for key in self.FIELDS:
                if reading.get(key) is not None:
                    item[key] = reading[key]
            if reading.get("battery") is None and item.get("battery") is None and reading.get("voltage"):
                item["battery"] = battery_from_voltage(reading["voltage"] * 1000)
            item["format"] = reading.get("format")
            item["updated"] = round(self.clock())
            item["error"] = None
            if rssi is not None:
                item["rssi"] = rssi
            if advertised_name:
                item["advertised_name"] = advertised_name
                if item["name"] == mac and mac not in self.configured:
                    item["name"] = advertised_name
        return True

    def set_error(self, mac, message):
        with self.lock:
            item = self.items.get(normalize_mac(mac))
            if item is not None:
                item["error"] = message

    def age(self, mac):
        item = self.items.get(normalize_mac(mac)) or {}
        return self.clock() - item["updated"] if item.get("updated") else None

    def snapshot(self, gateway_name):
        with self.lock:
            sensors = []
            for item in self.items.values():
                if item.get("updated") is None and item["id"] not in self.configured:
                    continue
                sensors.append({
                    "id": item["id"], "name": item.get("name") or item["id"],
                    "advertised_name": item.get("advertised_name"),
                    "temperature": item.get("temperature"), "humidity": item.get("humidity"),
                    "battery": item.get("battery"), "voltage": item.get("voltage"),
                    "rssi": item.get("rssi"), "updated": item.get("updated"),
                    "format": item.get("format"), "error": item.get("error"),
                })
        sensors.sort(key=lambda s: (s["name"].lower(), s["id"]))
        return {"version": API_VERSION, "gateway": gateway_name, "time": round(self.clock()), "sensors": sensors}

    def save(self):
        if not self.state_path:
            return
        data = json.dumps(self.snapshot(""), ensure_ascii=False, indent=1)
        tmp = Path(str(self.state_path) + ".tmp")
        tmp.write_text(data, encoding="utf-8")
        tmp.replace(self.state_path)


SAMPLE_SECONDS = 300
# range -> (days, bucket in seconds): the day as 30-minute points, as in Mi Home's day view;
# the week and month as one point per local calendar day with its lowest and highest.
RANGES = {"day": (1, 1800), "week": (7, 86400), "month": (30, 86400)}


def _round2(value):
    return None if value is None else round(value, 2)


class History:
    """5-minute samples per thermometer in SQLite, averaged into buckets when queried."""

    def __init__(self, path=":memory:", keep_days=90, clock=time.time, utc_offset=None):
        self.clock = clock
        self.keep_days = keep_days
        self.offset = utc_offset  # None: this PC's local time zone (days start at local midnight)
        self.lock = threading.Lock()
        self.db = sqlite3.connect(str(path), check_same_thread=False)
        self.db.execute("CREATE TABLE IF NOT EXISTS samples (mac TEXT NOT NULL, t INTEGER NOT NULL, "
                        "temperature REAL, humidity REAL, battery INTEGER, PRIMARY KEY (mac, t))")
        self.db.commit()

    def record(self, store, interval=SAMPLE_SECONDS):
        """One sample (at the start of the current interval) for each thermometer heard within
        the last interval. Returns the number of samples written."""
        now = round(self.clock())
        t = now - now % interval
        rows = [(s["id"], t, s["temperature"], s["humidity"], s["battery"])
                for s in store.snapshot("")["sensors"]
                if s["updated"] is not None and now - s["updated"] <= interval
                and (s["temperature"] is not None or s["humidity"] is not None)]
        self.add(rows)
        return len(rows)

    def add(self, rows):
        with self.lock:
            self.db.executemany("INSERT OR REPLACE INTO samples VALUES (?, ?, ?, ?, ?)", rows)
            self.db.execute("DELETE FROM samples WHERE t < ?", (round(self.clock()) - self.keep_days * 86400,))
            self.db.commit()

    def utc_offset(self):
        if self.offset is not None:
            return self.offset
        return time.localtime(self.clock()).tm_gmtoff

    def query(self, mac, range_name):
        """day: the last 24 hours in 30-minute points; week and month: one point per local
        calendar day (the last 7 or 30, today included), each with the day's lowest and highest."""
        days, bucket = RANGES[range_name]
        now = round(self.clock())
        off = self.utc_offset()
        if range_name == "day":
            start = now - 86400
        else:
            start = (now + off) // 86400 * 86400 - off - (days - 1) * 86400
        with self.lock:
            rows = self.db.execute(
                "SELECT ((t + ?) / ?) * ? - ? AS b, AVG(temperature), AVG(humidity), MIN(battery), "
                "MIN(temperature), MAX(temperature), MIN(humidity), MAX(humidity) FROM samples "
                "WHERE mac = ? AND t >= ? GROUP BY b ORDER BY b",
                (off, bucket, bucket, off, normalize_mac(mac), start)).fetchall()
        points = [{"t": b, "temperature": _round2(temp), "humidity": _round2(hum), "battery": batt,
                   "temperature_min": _round2(tmin), "temperature_max": _round2(tmax),
                   "humidity_min": _round2(hmin), "humidity_max": _round2(hmax)}
                  for b, temp, hum, batt, tmin, tmax, hmin, hmax in rows]
        return {"version": API_VERSION, "id": normalize_mac(mac), "range": range_name, "bucket": bucket,
                "time": now, "utc_offset": off, "points": points}

    def seed_demo(self, store, days=30):
        """Made-up daily curves for the fake mode, ending at each thermometer's reading."""
        now = round(self.clock())
        rows = []
        for item in store.snapshot("")["sensors"]:
            if item["temperature"] is None:
                continue
            phase = int(item["id"][-2:], 16)
            end = item["updated"] or now
            for k in range(days * 86400 // SAMPLE_SECONDS):
                t = end - end % SAMPLE_SECONDS - k * SAMPLE_SECONDS
                day = math.sin(2 * math.pi * (t % 86400) / 86400 + phase)
                drift = math.sin(2 * math.pi * t / (5 * 86400))
                rows.append((item["id"], t, round(item["temperature"] + 1.8 * day - 1.8 * math.sin(phase) + 0.6 * drift, 2),
                             round(max(5.0, min(99.0, (item["humidity"] or 50) - 6 * day + 6 * math.sin(phase))), 2),
                             min(100, (item["battery"] or 50) + k * SAMPLE_SECONDS // (10 * 86400))))
        self.add(rows)


class BleWorker:
    """Scans continuously; pauses the scan to connect to stock-firmware thermometers."""

    def __init__(self, cfg, store):
        self.cfg = cfg
        self.store = store
        self.gatt = [normalize_mac(s["mac"]) for s in cfg.get("sensors", []) if s.get("gatt")]
        self.poll_seconds = int(cfg.get("gatt_poll_seconds", 300))
        self.last_advert = time.time()
        self.next_poll = {}

    def on_advert(self, device, adv):
        self.last_advert = time.time()
        reading = decode_service_data(adv.service_data)
        if reading:
            self.store.update(device.address, reading, adv.rssi, adv.local_name)

    async def read_gatt(self, mac):
        import asyncio
        from bleak import BleakClient, BleakScanner
        dev = await BleakScanner.find_device_by_address(mac, timeout=20)
        if dev is None:
            raise RuntimeError("找不到裝置")
        got = asyncio.get_running_loop().create_future()

        def cb(_, data):
            if not got.done():
                got.set_result(bytes(data))

        async with BleakClient(dev, timeout=20) as client:
            await client.start_notify(CHAR_MI_TEMP, cb)
            data = await asyncio.wait_for(got, 20)
        temp, hum, mv = struct.unpack("<hBH", data[:5])
        return {"format": "gatt", "temperature": temp / 100, "humidity": float(hum),
                "voltage": mv / 1000, "battery": battery_from_voltage(mv)}

    async def run(self):
        import asyncio
        from bleak import BleakScanner
        while True:
            scanner = BleakScanner(self.on_advert, scanning_mode="active")
            try:
                await scanner.start()
                self.last_advert = time.time()
                while True:
                    await asyncio.sleep(5)
                    if time.time() - self.last_advert > 300:
                        logging.warning("No advertisement for 5 minutes; restarting the scan")
                        break
                    due = [m for m in self.gatt if time.time() >= self.next_poll.get(m, 0)
                           and (self.store.age(m) is None or self.store.age(m) > self.poll_seconds)]
                    if due:
                        break
            except Exception:
                logging.exception("Scan failed")
                await asyncio.sleep(10)
            finally:
                try:
                    await scanner.stop()
                except Exception:
                    pass
            for mac in [m for m in self.gatt if time.time() >= self.next_poll.get(m, 0)]:
                age = self.store.age(mac)
                if age is not None and age <= self.poll_seconds:
                    continue
                self.next_poll[mac] = time.time() + self.poll_seconds
                try:
                    self.store.update(mac, await self.read_gatt(mac))
                except Exception as exc:
                    logging.warning("GATT read of %s failed: %s", mac, exc)
                    self.store.set_error(mac, "連線讀取失敗")


def load_fake(path, clock=time.time):
    """Fixture readings; each sensor's age_seconds becomes its update time."""
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    store = Store(data.get("sensors", []), discover=True, clock=clock)
    for item in data.get("sensors", []):
        if "age_seconds" in item:
            reading = {k: item.get(k) for k in Store.FIELDS}
            reading["format"] = item.get("format", "bthome")
            store.update(item["mac"], reading, item.get("rssi"), item.get("advertised_name"))
            store.items[normalize_mac(item["mac"])]["updated"] = round(clock() - item["age_seconds"])
        if item.get("error"):
            store.set_error(item["mac"], item["error"])
    return store, data.get("gateway_name", "示範閘道")


def handler_for(store, gateway_name, networks, history=None):
    class Handler(BaseHTTPRequestHandler):
        server_version = "ThermoGateway/1"

        def log_message(self, fmt, *args):
            logging.debug("%s " + fmt, self.client_address[0], *args)

        def send_json(self, code, obj):
            body = json.dumps(obj, ensure_ascii=False, allow_nan=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def allowed(self):
            try:
                peer = ipaddress.ip_address(self.client_address[0])
            except ValueError:
                return False
            return any(peer in network for network in networks)

        def do_GET(self):
            if not self.allowed():
                return self.send_json(403, {"error": "forbidden"})
            path, _, query = self.path.partition("?")
            if path == "/sensors":
                return self.send_json(200, store.snapshot(gateway_name))
            if path == "/history":
                params = parse_qs(query)
                mac = normalize_mac((params.get("id") or [""])[0])
                range_name = (params.get("range") or ["day"])[0]
                if range_name not in RANGES:
                    return self.send_json(400, {"error": "range must be day, week or month"})
                if history is None or mac not in store.items:
                    return self.send_json(404, {"error": "unknown thermometer"})
                return self.send_json(200, history.query(mac, range_name))
            if path == "/health":
                return self.send_json(200, {"ok": True})
            return self.send_json(404, {"error": "not found"})

        def denied(self):
            self.send_json(405, {"error": "method not allowed"})

        do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_HEAD = denied

    return Handler


def check_bind(bind_ip, allowed_networks):
    networks = [ipaddress.ip_network(item) for item in allowed_networks]
    bind = ipaddress.ip_address(bind_ip)
    if bind.is_unspecified or not any(bind in network for network in networks):
        raise RuntimeError("bind_ip must be a specific address inside allowed_networks (no 0.0.0.0)")
    return networks


def serve(bind_ip, port, handler):
    while True:
        try:
            return ThreadingHTTPServer((bind_ip, port), handler)
        except OSError as exc:
            if getattr(exc, "winerror", None) != 10049:
                raise
            time.sleep(10)  # ZeroTier not up yet; never fall back to another interface.


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--config", default=str(ROOT / "thermo-gateway.json"))
    parser.add_argument("--fake", help="serve fixture readings, no Bluetooth")
    parser.add_argument("--bind", default="127.0.0.1", help="fake mode only")
    parser.add_argument("--port", type=int, default=8795, help="fake mode only")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    if args.fake:
        store, name = load_fake(args.fake)
        history = History()
        history.seed_demo(store)
        networks = check_bind(args.bind, ["127.0.0.0/8"])
        server = serve(args.bind, args.port, handler_for(store, name, networks, history))
        print(f"Fake thermometer gateway on {args.bind}:{args.port}", flush=True)
        server.serve_forever(poll_interval=0.5)
        return

    import asyncio
    config_path = Path(args.config)
    cfg = json.loads(config_path.read_text(encoding="utf-8-sig"))
    networks = check_bind(cfg["bind_ip"], cfg["allowed_networks"])
    log = RotatingFileHandler(config_path.with_name("thermo-gateway.log"), maxBytes=1048576, backupCount=2, encoding="utf-8")
    log.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%Y-%m-%d %H:%M:%S"))
    logging.getLogger().addHandler(log)
    store = Store(cfg.get("sensors", []), discover=cfg.get("discover", True),
                  state_path=config_path.with_name("thermo-state.json"))
    worker = BleWorker(cfg, store)
    threading.Thread(target=lambda: asyncio.run(worker.run()), daemon=True).start()

    history = History(config_path.with_name("thermo-history.sqlite"), keep_days=int(cfg.get("history_days", 90)))

    def saver():
        while True:
            time.sleep(SAMPLE_SECONDS - time.time() % SAMPLE_SECONDS + 1)
            try:
                store.save()
                history.record(store)
            except (OSError, sqlite3.Error):
                logging.exception("Saving the state or history failed")

    threading.Thread(target=saver, daemon=True).start()
    server = serve(cfg["bind_ip"], int(cfg.get("port", 18787)),
                   handler_for(store, cfg.get("gateway_name", "閘道"), networks, history))
    logging.info("Thermometer gateway listening on the configured address")
    server.daemon_threads = True
    server.serve_forever(poll_interval=1)


if __name__ == "__main__":
    main()
