import json
import struct
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import thermo_gateway as tg  # noqa: E402  (must import without bleak installed)

FIXTURE = HERE.parent.parent / "fixtures" / "fake-sensors.json"


class Clock:
    def __init__(self, now=1_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


class DecodeTests(unittest.TestCase):
    def test_bthome_from_a_real_pvvx_thermometer(self):
        # Captured from an LYWSD03MMC on pvvx firmware 5.9 (packet id, battery, temperature, humidity).
        r = tg.decode_bthome(bytes.fromhex("40000c015d02ac0903b51a"))
        self.assertEqual(r, {"format": "bthome", "battery": 93, "temperature": 24.76, "humidity": 68.37})

    def test_bthome_voltage_packet(self):
        r = tg.decode_bthome(bytes.fromhex("40000d0c890b"))
        self.assertEqual(r, {"format": "bthome", "voltage": 2.953})

    def test_bthome_negative_temperature(self):
        r = tg.decode_bthome(bytes([0x40, 0x02]) + struct.pack("<h", -1234))
        self.assertAlmostEqual(r["temperature"], -12.34)

    def test_bthome_encrypted_is_skipped(self):
        self.assertIsNone(tg.decode_bthome(bytes.fromhex("41000c015d02ac0903b51a")))

    def test_bthome_other_version_is_skipped(self):
        self.assertIsNone(tg.decode_bthome(bytes.fromhex("20015d")))

    def test_bthome_stops_at_unknown_object(self):
        r = tg.decode_bthome(bytes.fromhex("4002ac09ff0102035d"))
        self.assertEqual(r, {"format": "bthome", "temperature": 24.76})

    def test_bthome_truncated_object_is_ignored(self):
        self.assertIsNone(tg.decode_bthome(bytes.fromhex("4002ac")))

    def test_pvvx_custom(self):
        data = bytes.fromhex("0a0000" "38c1a4") + struct.pack("<hHHBBB", 2513, 6450, 2953, 87, 5, 0x04)
        r = tg.decode_env(data)
        self.assertEqual(r, {"format": "pvvx", "temperature": 25.13, "humidity": 64.5, "voltage": 2.953, "battery": 87})

    def test_atc1441(self):
        data = bytes.fromhex("a4c13800000a") + struct.pack(">hBBHB", 251, 64, 87, 2953, 9)
        r = tg.decode_env(data)
        self.assertEqual(r, {"format": "atc1441", "temperature": 25.1, "humidity": 64.0, "voltage": 2.953, "battery": 87})

    def test_env_encrypted_length_is_skipped(self):
        self.assertIsNone(tg.decode_env(bytes(11)))

    def test_service_data_ignores_mibeacon(self):
        self.assertIsNone(tg.decode_service_data({"0000fe95-0000-1000-8000-00805f9b34fb": bytes.fromhex("58585b05")}))
        r = tg.decode_service_data({"0000FCD2-0000-1000-8000-00805F9B34FB": bytes.fromhex("4002ac09")})
        self.assertEqual(r["temperature"], 24.76)

    def test_battery_from_voltage(self):
        self.assertEqual(tg.battery_from_voltage(3100), 100)
        self.assertEqual(tg.battery_from_voltage(2200), 0)
        self.assertEqual(tg.battery_from_voltage(2953), 84)
        self.assertEqual(tg.battery_from_voltage(3300), 100)
        self.assertIsNone(tg.battery_from_voltage(None))


class StoreTests(unittest.TestCase):
    def test_alternating_packets_merge(self):
        clock = Clock()
        s = tg.Store(clock=clock)
        s.update("a4:c1:38:00:00:0a", {"format": "bthome", "temperature": 24.76, "humidity": 68.37, "battery": 93}, -45, "ATC_00000A")
        clock.now += 10
        s.update("A4-C1-38-00-00-0A", {"format": "bthome", "voltage": 2.953}, -47)
        snap = s.snapshot("office")
        self.assertEqual(len(snap["sensors"]), 1)
        item = snap["sensors"][0]
        self.assertEqual(item["id"], "A4:C1:38:00:00:0A")
        self.assertEqual((item["temperature"], item["humidity"], item["battery"], item["voltage"]), (24.76, 68.37, 93, 2.953))
        self.assertEqual(item["name"], "ATC_00000A")
        self.assertEqual(item["rssi"], -47)
        self.assertEqual(item["updated"], 1_000_010)
        self.assertEqual(snap["version"], 1)
        self.assertEqual(snap["gateway"], "office")

    def test_configured_name_wins_and_listed_sensor_shows_before_first_reading(self):
        s = tg.Store([{"mac": "A4:C1:38:00:00:01", "name": "座位"}], clock=Clock())
        self.assertEqual(s.snapshot("g")["sensors"][0]["updated"], None)
        s.update("A4:C1:38:00:00:01", {"format": "bthome", "temperature": 20.0}, None, "ATC_000001")
        item = s.snapshot("g")["sensors"][0]
        self.assertEqual(item["name"], "座位")
        self.assertEqual(item["advertised_name"], "ATC_000001")

    def test_discover_off_ignores_unlisted(self):
        s = tg.Store([{"mac": "A4:C1:38:00:00:01"}], discover=False, clock=Clock())
        self.assertFalse(s.update("A4:C1:38:00:00:09", {"temperature": 1.0}))
        self.assertEqual([x["id"] for x in s.snapshot("g")["sensors"]], ["A4:C1:38:00:00:01"])

    def test_battery_estimated_from_voltage_only_when_missing(self):
        s = tg.Store(clock=Clock())
        s.update("A4:C1:38:00:00:01", {"format": "gatt", "voltage": 2.65})
        self.assertEqual(s.snapshot("g")["sensors"][0]["battery"], 50)

    def test_error_is_cleared_by_a_reading(self):
        s = tg.Store([{"mac": "A4:C1:38:00:00:02", "gatt": True}], clock=Clock())
        s.set_error("A4:C1:38:00:00:02", "連線讀取失敗")
        self.assertEqual(s.snapshot("g")["sensors"][0]["error"], "連線讀取失敗")
        s.update("A4:C1:38:00:00:02", {"format": "gatt", "temperature": 23.0})
        self.assertIsNone(s.snapshot("g")["sensors"][0]["error"])

    def test_state_survives_a_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.json"
            clock = Clock()
            s = tg.Store(state_path=path, clock=clock)
            s.update("A4:C1:38:00:00:01", {"format": "bthome", "temperature": 21.5, "humidity": 50.0}, -60, "ATC_000001")
            s.save()
            again = tg.Store([{"mac": "A4:C1:38:00:00:01", "name": "座位"}], state_path=path, clock=clock)
            item = again.snapshot("g")["sensors"][0]
            self.assertEqual((item["name"], item["temperature"], item["updated"]), ("座位", 21.5, 1_000_000))
            self.assertEqual(item["advertised_name"], "ATC_000001")

    def test_age(self):
        clock = Clock()
        s = tg.Store(clock=clock)
        self.assertIsNone(s.age("A4:C1:38:00:00:01"))
        s.update("A4:C1:38:00:00:01", {"temperature": 1.0})
        clock.now += 42
        self.assertEqual(s.age("A4:C1:38:00:00:01"), 42)


class HistoryTests(unittest.TestCase):
    def test_records_only_recently_heard_thermometers(self):
        clock = Clock(1_000_000.0)  # 999_900 is the 5-minute interval start
        store = tg.Store([{"mac": "A4:C1:38:00:00:09", "name": "沒聲音"}], clock=clock)
        store.update("A4:C1:38:00:00:01", {"temperature": 21.0, "humidity": 50.0, "battery": 90})
        clock.now -= 400
        store.update("A4:C1:38:00:00:02", {"temperature": 30.0})
        clock.now += 400
        history = tg.History(clock=clock, utc_offset=0)
        self.assertEqual(history.record(store), 1)
        rows = history.db.execute("SELECT mac, t FROM samples").fetchall()
        self.assertEqual(rows, [("A4:C1:38:00:00:01", 999_900)])
        result = history.query("a4:c1:38:00:00:01", "day")
        self.assertEqual(result["points"], [{"t": 999_000, "temperature": 21.0, "humidity": 50.0, "battery": 90,
                                             "temperature_min": 21.0, "temperature_max": 21.0,
                                             "humidity_min": 50.0, "humidity_max": 50.0}])
        self.assertEqual(history.query("A4:C1:38:00:00:02", "day")["points"], [])

    def test_day_is_half_hours_and_week_is_local_calendar_days(self):
        taipei = 8 * 3600
        midnight = 20 * 86400 - taipei          # local midnight in UTC+8
        clock = Clock(midnight + 10 * 3600)     # 10:00 local
        history = tg.History(clock=clock, utc_offset=taipei)
        mac = "A4:C1:38:00:00:01"
        history.add([
            (mac, midnight + 9 * 3600, 20.0, 40.0, 80), (mac, midnight + 9 * 3600 + 600, 24.0, 60.0, 79),
            (mac, midnight - 3600, 30.0, 70.0, 81),           # 23:00 yesterday, local
            (mac, midnight - 6 * 86400 + 60, 15.0, 30.0, 90),  # 6 days ago: still in the week
            (mac, midnight - 7 * 86400 + 60, 99.0, 99.0, 99),  # 7 days ago: out of the week
        ])
        day = history.query(mac, "day")
        self.assertEqual(day["bucket"], 1800)
        self.assertEqual(day["utc_offset"], taipei)
        self.assertEqual([p["t"] for p in day["points"]], [midnight - 3600, midnight + 9 * 3600])
        self.assertEqual(day["points"][-1]["temperature"], 22.0)
        week = history.query(mac, "week")
        self.assertEqual(week["bucket"], 86400)
        self.assertEqual([p["t"] for p in week["points"]], [midnight - 6 * 86400, midnight - 86400, midnight])
        today = week["points"][-1]
        self.assertEqual((today["temperature_min"], today["temperature_max"], today["humidity_min"], today["humidity_max"]),
                         (20.0, 24.0, 40.0, 60.0))
        self.assertEqual(today["battery"], 79)
        self.assertEqual(len(history.query(mac, "month")["points"]), 4)

    def test_old_samples_are_dropped(self):
        clock = Clock(100 * 86400.0)
        history = tg.History(keep_days=90, clock=clock)
        history.add([("A4:C1:38:00:00:01", 5 * 86400, 1.0, 1.0, 1)])
        count = history.db.execute("SELECT COUNT(*) FROM samples").fetchone()[0]
        self.assertEqual(count, 0)

    def test_history_survives_a_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "h.sqlite"
            clock = Clock(86400.0)
            first = tg.History(path, clock=clock)
            first.add([("A4:C1:38:00:00:01", 86100, 20.0, 40.0, 80)])
            first.db.close()
            again = tg.History(path, clock=clock)
            self.assertEqual(len(again.query("A4:C1:38:00:00:01", "day")["points"]), 1)
            again.db.close()

    def test_demo_seed_gives_a_month_of_curves(self):
        clock = Clock()
        store, _ = tg.load_fake(FIXTURE, clock=clock)
        history = tg.History(clock=clock)
        history.seed_demo(store)
        month = history.query("A4:C1:38:00:00:01", "month")["points"]
        self.assertIn(len(month), (30, 31))
        self.assertGreater(month[-2]["temperature_max"] - month[-2]["temperature_min"], 2.0)
        temps = [p["temperature"] for p in history.query("A4:C1:38:00:00:01", "day")["points"]]
        self.assertGreater(max(temps) - min(temps), 2.0)
        self.assertEqual(history.query("A4:C1:38:00:00:04", "day")["points"], [])


class LabelTests(unittest.TestCase):
    def test_phone_label_wins_and_clears(self):
        store = tg.Store([{"mac": "A4:C1:38:00:00:01", "name": "座位"}], clock=Clock())
        self.assertTrue(store.set_label("a4:c1:38:00:00:01", "  書房溫度計 ", "書房"))
        item = store.snapshot("g")["sensors"][0]
        self.assertEqual((item["name"], item["room"]), ("書房溫度計", "書房"))
        store.set_label("A4:C1:38:00:00:01", "", None)
        item = store.snapshot("g")["sensors"][0]
        self.assertEqual((item["name"], item["room"]), ("座位", None))
        self.assertFalse(store.set_label("A4:C1:38:00:00:99", "x", None))
        store.set_label("A4:C1:38:00:00:01", "長" * 100, None)
        self.assertEqual(len(store.snapshot("g")["sensors"][0]["name"]), tg.MAX_LABEL)

    def test_labels_survive_a_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.json"
            store = tg.Store([{"mac": "A4:C1:38:00:00:01", "name": "座位"}], state_path=path, clock=Clock())
            store.set_label("A4:C1:38:00:00:01", "書房溫度計", "書房")
            store.save()
            again = tg.Store([{"mac": "A4:C1:38:00:00:01", "name": "座位"}], state_path=path, clock=Clock())
            item = again.snapshot("g")["sensors"][0]
            self.assertEqual((item["name"], item["room"]), ("書房溫度計", "書房"))
            again.set_label("A4:C1:38:00:00:01", None, None)
            self.assertEqual(again.snapshot("g")["sensors"][0]["name"], "座位", "the config name is still known")


class NotifierTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock(1_000_000.0)
        self.store = tg.Store(clock=self.clock)
        self.sent = []
        cfg = {"notify": {"topic": "test-topic"},
               "alerts": {"temperature_high": 30, "sensors": {"a4:c1:38:00:00:02": {"temperature_high": None}}}}
        self.notifier = tg.Notifier(cfg, self.store, send=lambda *a: self.sent.append(a), clock=self.clock)

    def reading(self, mac, **values):
        self.store.update(mac, {"format": "bthome", **values})

    def test_out_of_range_waits_for_the_hold_and_is_sent_once(self):
        self.reading("A4:C1:38:00:00:01", temperature=31.2, humidity=50.0, battery=90)
        self.store.set_label("A4:C1:38:00:00:01", "Office A", "書房")
        self.assertEqual(self.notifier.check(), 0, "not before hold_seconds")
        self.clock.now += 600
        self.reading("A4:C1:38:00:00:01", temperature=31.0)
        self.assertEqual(self.notifier.check(), 1)
        title, message, priority, tags = self.sent[0]
        self.assertTrue(title.endswith("書房・Office A 溫度過高"), title)
        self.assertEqual(message, "31.0°C（上限 30°C）")
        self.assertEqual(priority, 4)
        self.assertNotIn("A4:C1", title + message, "no addresses in notifications")
        self.clock.now += 600
        self.assertEqual(self.notifier.check(), 0, "sent once")

    def test_margin_before_it_can_be_sent_again_and_no_recovery_message(self):
        self.reading("A4:C1:38:00:00:01", temperature=31.0)
        self.notifier.check()
        self.clock.now += 600
        self.reading("A4:C1:38:00:00:01", temperature=31.0)
        self.notifier.check()
        self.assertEqual(len(self.sent), 1)
        self.reading("A4:C1:38:00:00:01", temperature=29.8)  # under 30 but within the 0.5 margin
        self.notifier.check()
        self.reading("A4:C1:38:00:00:01", temperature=29.0)  # clearly back
        self.notifier.check()
        self.assertEqual(len(self.sent), 1, "no recovery notification")
        self.reading("A4:C1:38:00:00:01", temperature=30.6)
        self.notifier.check()
        self.clock.now += 600
        self.reading("A4:C1:38:00:00:01", temperature=30.6)
        self.notifier.check()
        self.assertEqual(len(self.sent), 2, "armed again after coming back")

    def test_humidity_battery_offline_and_overrides(self):
        self.reading("A4:C1:38:00:00:02", temperature=40.0, humidity=85.0, battery=10)
        self.assertEqual(self.notifier.check(), 1, "a low battery is sent at once")
        self.assertIn("電量不足", self.sent[0][0])
        self.assertEqual(self.sent[0][2], 3)
        self.clock.now += 600
        self.reading("A4:C1:38:00:00:02", temperature=40.0, humidity=85.0)
        self.notifier.check()
        self.assertEqual(len(self.sent), 2)
        self.assertIn("濕度過高", self.sent[1][0])
        self.assertFalse(any("溫度過高" in t for t, *_ in self.sent), "temperature_high is off for this one")
        self.clock.now += 7200
        self.assertEqual(self.notifier.check(), 1)
        self.assertIn("收不到訊號", self.sent[-1][0])
        self.assertFalse(any("濕度過低" in t or "溫度過低" in t for t, *_ in self.sent))

    def test_stale_readings_are_not_judged(self):
        self.reading("A4:C1:38:00:00:01", temperature=5.0)
        self.clock.now += 3600
        self.assertEqual(self.notifier.check(), 0, "an hour-old reading is not an alarm (offline covers it later)")

    def test_off_without_a_topic_and_topic_from_another_file(self):
        quiet = tg.Notifier({}, self.store, send=lambda *a: self.sent.append(a))
        self.assertFalse(quiet.enabled)
        self.reading("A4:C1:38:00:00:01", battery=1)
        self.assertEqual(quiet.check(), 0)
        with tempfile.TemporaryDirectory() as tmp:
            other = Path(tmp) / "other.json"
            other.write_text(json.dumps({"notify": {"server": "https://ntfy.example", "topic": "shared"}}), encoding="utf-8")
            shared = tg.Notifier({"notify": {"from_file": str(other)}}, self.store)
            self.assertEqual((shared.server, shared.topic), ("https://ntfy.example", "shared"))
            self.assertTrue(shared.summary()["enabled"])
            self.assertEqual(shared.summary()["temperature_high"], 32.0)


class FakeAndHttpTests(unittest.TestCase):
    def test_fixture_ages_and_error(self):
        clock = Clock()
        store, name = tg.load_fake(FIXTURE, clock=clock)
        snap = store.snapshot(name)
        by_name = {s["name"]: s for s in snap["sensors"]}
        self.assertEqual(name, "示範閘道")
        self.assertEqual(set(by_name), {"客廳", "臥室", "機房", "陽台"})
        self.assertEqual(by_name["機房"]["updated"], 1_000_000 - 2400)
        self.assertIsNone(by_name["陽台"]["updated"])
        self.assertEqual(by_name["陽台"]["error"], "連線讀取失敗")
        self.assertTrue(all(s["id"].startswith("A4:C1:38:00:00:") for s in snap["sensors"]), "fixtures use made-up addresses")

    def test_bind_must_be_specific_and_inside_the_allowed_networks(self):
        with self.assertRaises(RuntimeError):
            tg.check_bind("0.0.0.0", ["0.0.0.0/0"])
        with self.assertRaises(RuntimeError):
            tg.check_bind("192.0.2.10", ["198.51.100.0/24"])
        self.assertEqual(len(tg.check_bind("192.0.2.10", ["192.0.2.0/24"])), 1)

    def _serve(self, networks):
        store, name = tg.load_fake(FIXTURE)
        history = tg.History()
        history.seed_demo(store)
        notifier = tg.Notifier({"alerts": {"temperature_high": 30}}, store, send=lambda *a: None)
        server = tg.ThreadingHTTPServer(("127.0.0.1", 0), tg.handler_for(store, name, networks, history, notifier))
        threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_address[1]}"

    def _get(self, url, method="GET"):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, method=method), timeout=5) as r:
                return r.status, json.loads(r.read().decode("utf-8")), r.headers
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode("utf-8")), e.headers

    def test_sensors_json(self):
        base = self._serve(tg.check_bind("127.0.0.1", ["127.0.0.0/8"]))
        code, body, headers = self._get(base + "/sensors")
        self.assertEqual(code, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(body["version"], 1)
        self.assertEqual(len(body["sensors"]), 4)
        self.assertEqual(set(body["sensors"][0]), {"id", "name", "label", "room", "advertised_name", "temperature", "humidity", "battery",
                                                   "voltage", "rssi", "updated", "format", "error"})
        self.assertEqual(self._get(base + "/health")[:2], (200, {"ok": True}))
        self.assertEqual(self._get(base + "/nope")[0], 404)
        self.assertEqual(self._get(base + "/sensors", "POST")[0], 405)

    def test_history_endpoint(self):
        base = self._serve(tg.check_bind("127.0.0.1", ["127.0.0.0/8"]))
        code, body, _ = self._get(base + "/history?id=a4%3Ac1%3A38%3A00%3A00%3A01&range=week")
        self.assertEqual(code, 200)
        self.assertEqual((body["version"], body["id"], body["range"], body["bucket"]), (1, "A4:C1:38:00:00:01", "week", 86400))
        self.assertEqual(set(body["points"][0]), {"t", "temperature", "humidity", "battery", "temperature_min",
                                                  "temperature_max", "humidity_min", "humidity_max"})
        self.assertEqual(self._get(base + "/history?id=A4:C1:38:00:00:01")[1]["range"], "day")
        self.assertEqual(self._get(base + "/history?id=A4:C1:38:00:00:01&range=year")[0], 400)
        self.assertEqual(self._get(base + "/history?id=A4:C1:38:00:00:77")[0], 404)

    def _post(self, url, body):
        data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(url, data=data, method="POST", headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=5) as r:
                return r.status, json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode("utf-8"))

    def test_labels_endpoint_and_alert_summary(self):
        base = self._serve(tg.check_bind("127.0.0.1", ["127.0.0.0/8"]))
        self.assertEqual(self._post(base + "/labels", {"id": "a4:c1:38:00:00:01", "name": "書房溫度計", "room": "書房"}),
                         (200, {"ok": True}))
        body = self._get(base + "/sensors")[1]
        item = next(s for s in body["sensors"] if s["id"] == "A4:C1:38:00:00:01")
        self.assertEqual((item["name"], item["room"]), ("書房溫度計", "書房"))
        self.assertEqual(body["alerts"]["temperature_high"], 30)
        self.assertFalse(body["alerts"]["enabled"])
        self.assertEqual(self._post(base + "/labels", {"id": "A4:C1:38:00:00:77", "name": "x"})[0], 404)
        self.assertEqual(self._post(base + "/labels", {"name": "x"})[0], 400)
        self.assertEqual(self._post(base + "/labels", {"id": "A4:C1:38:00:00:01", "name": 5})[0], 400)
        self.assertEqual(self._post(base + "/labels", b"x" * 2000)[0], 400)
        self.assertEqual(self._post(base + "/other", {"id": "x"})[0], 405)

    def test_clients_outside_the_allowed_networks_are_refused(self):
        base = self._serve([tg.ipaddress.ip_network("192.0.2.0/24")])
        code, body, _ = self._get(base + "/sensors")
        self.assertEqual((code, body), (403, {"error": "forbidden"}))

    def test_module_does_not_need_bleak(self):
        self.assertNotIn("bleak", sys.modules)


if __name__ == "__main__":
    unittest.main()
