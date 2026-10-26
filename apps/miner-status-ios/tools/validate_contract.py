#!/usr/bin/env python3
"""Contract checks for schema/miner-status.schema.json and fixtures/*.json.

Uses the already-installed `jsonschema` package plus a strict RFC 3339 date-time check built on
the standard library (jsonschema's FormatChecker has no date-time checker without extra packages).

This checks the JSON contract only. It is NOT a test of the Swift StatusEngine and does not replace
the XCTest suite, which needs an Apple toolchain.

Usage:   python tools/validate_contract.py [--verbose]
Exit 0 only if every fixture is valid and every positive/negative case behaves as expected.
"""
from __future__ import annotations

import copy
import json
import re
import sys
from datetime import datetime
from importlib.metadata import version
from pathlib import Path

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:
    sys.exit("jsonschema is not installed; this script never installs packages.")

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "schema" / "miner-status.schema.json"
FIXTURES = ROOT / "fixtures"
BASE_FIXTURE = FIXTURES / "demo-running.json"

_RFC3339 = re.compile(
    r"([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]{1,9})?"
    r"(Z|[+-]([0-9]{2}):([0-9]{2}))"
)


def strict_date_time(value: object) -> bool:
    """Mirrors the Swift Timestamp parser: ASCII digits, explicit offset, real date, no leap second."""
    if not isinstance(value, str):
        return True  # format only constrains strings; the type keyword handles the rest
    match = _RFC3339.fullmatch(value)
    if not match:
        return False
    year, month, day, hour, minute, second = (int(group) for group in match.groups()[:6])
    if second == 60:
        return False
    try:
        datetime(year, month, day, hour, minute, second)
    except ValueError:
        return False
    if match.group(8) != "Z" and (int(match.group(9)) > 23 or int(match.group(10)) > 59):
        return False
    return True


def make_validator() -> Draft202012Validator:
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    checker = FormatChecker(formats=())
    checker.checks("date-time")(strict_date_time)
    return Draft202012Validator(schema, format_checker=checker)


def extra_rule_errors(feed: object) -> list[str]:
    """Rules the Swift decoder enforces that JSON Schema cannot express."""
    errors: list[str] = []
    machines = feed.get("machines") if isinstance(feed, dict) else None
    if isinstance(machines, list):
        ids = [m.get("machineId") for m in machines if isinstance(m, dict)]
        duplicates = sorted({i for i in ids if isinstance(i, str) and ids.count(i) > 1})
        if duplicates:
            errors.append(f"duplicate machineId {duplicates}")
    return errors


def contract_errors(validator: Draft202012Validator, feed: object) -> list[str]:
    errors = [
        f"{'/'.join(map(str, error.absolute_path)) or '<root>'}: {error.message}"
        for error in validator.iter_errors(feed)
    ]
    return errors + extra_rule_errors(feed)


def demo_label_errors(feed: dict) -> list[str]:
    """Fixture policy: every fixture is visibly synthetic demo data."""
    errors: list[str] = []
    if feed.get("dataOrigin") != "demo":
        errors.append("fixture must have dataOrigin demo")
    if "示範" not in (feed.get("demoNotice") or ""):
        errors.append("demoNotice must say 示範")
    for machine in feed.get("machines", []):
        label = machine.get("machineId")
        if not str(label).startswith("demo-"):
            errors.append(f"{label}: machineId must start with demo-")
        if "DEMO" not in str(machine.get("displayName")):
            errors.append(f"{label}: displayName must contain DEMO")
        for key in ("worker", "sessionId"):
            value = machine.get(key)
            if value is not None and not value.startswith("demo-"):
                errors.append(f"{label}: {key} must be null or start with demo-")
    return errors


_PRIVATE_PATTERNS = [
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"), "IPv4-like address"),
    (re.compile(r"[A-Za-z]:\\\\|/Users/|/home/"), "filesystem path"),
    (re.compile(r"(?i)token|wallet|password|secret|api[_-]?key|\bpid\b"), "credential-like or non-whitelisted word"),
]


def privacy_errors(text: str) -> list[str]:
    return [label for pattern, label in _PRIVATE_PATTERNS if pattern.search(text)]


# MARK: - Mutation cases

_DELETE = object()
M = ("machines", 0)


def apply(feed: dict, edits: list[tuple[tuple, object]]) -> dict:
    result = copy.deepcopy(feed)
    for path, value in edits:
        target = result
        for key in path[:-1]:
            target = target[key]
        if value is _DELETE:
            del target[path[-1]]
        else:
            target[path[-1]] = value
    return result


def build_cases(base: dict) -> tuple[list, list]:
    machine = base["machines"][0]
    negative: list[tuple[str, list]] = []
    positive: list[tuple[str, list]] = []

    # Every key is required, at every level.
    negative += [(f"missing feed.{k}", [((k,), _DELETE)]) for k in base]
    negative += [(f"missing machine.{k}", [(M + (k,), _DELETE)]) for k in machine]
    for parent in ("minerRunning", "hashrate", "shares", "stop"):
        negative += [(f"missing {parent}.{k}", [(M + (parent, k), _DELETE)]) for k in machine[parent]]
    negative += [(f"missing gpus[0].{k}", [(M + ("gpus", 0, k), _DELETE)]) for k in machine["gpus"][0]]

    # Whitelist: no extra keys anywhere.
    negative += [
        ("extra feed.token", [(("token",), "x")]),
        ("extra machine.pid", [(M + ("pid",), 1234)]),
        ("extra minerRunning.pid", [(M + ("minerRunning", "pid"), 1234)]),
        ("extra hashrate.raw", [(M + ("hashrate", "raw"), "x")]),
        ("extra shares.log", [(M + ("shares", "log"), "x")]),
        ("extra stop.message", [(M + ("stop", "message"), "x")]),
        ("extra gpus[0].limit", [(M + ("gpus", 0, "limit"), 70)]),
    ]

    # Types and enums; booleans must not pass as integers or vice versa.
    negative += [
        ("schemaVersion 2", [(("schemaVersion",), 2)]),
        ("schemaVersion true", [(("schemaVersion",), True)]),
        ("dataOrigin test", [(("dataOrigin",), "test")]),
        ("machines null", [(("machines",), None)]),
        ("accepted as string", [(M + ("shares", "accepted"), "10")]),
        ("accepted as bool", [(M + ("shares", "accepted"), True)]),
        ("accepted fractional", [(M + ("shares", "accepted"), 10.5)]),
        ("sampleSequence as string", [(M + ("sampleSequence",), "1")]),
        ("expectedRunning yes", [(M + ("expectedRunning",), "yes")]),
        ("expectedRunning 1", [(M + ("expectedRunning",), 1)]),
        ("expectedRunning 0", [(M + ("expectedRunning",), 0)]),
        ("minerRunning.state paused", [(M + ("minerRunning", "state"), "paused")]),
        ("minerRunning.state true", [(M + ("minerRunning", "state"), True)]),
        ("stop.reason crash", [(M + ("stop", "reason"), "crash")]),
        ("hashrate.unit PH/s", [(M + ("hashrate", "unit"), "PH/s")]),
        ("hashrate.value as string", [(M + ("hashrate", "value"), "70")]),
        ("sourceStatus offline", [(M + ("sourceStatus",), "offline")]),
        ("gpus as object", [(M + ("gpus",), {})]),
        ("worker as number", [(M + ("worker",), 1)]),
    ]

    # Ranges.
    negative += [
        ("accepted -1", [(M + ("shares", "accepted"), -1)]),
        ("stale -1", [(M + ("shares", "stale"), -1)]),
        ("rejected -1", [(M + ("shares", "rejected"), -1)]),
        ("sampleSequence -1", [(M + ("sampleSequence",), -1)]),
        ("hashrate -0.1", [(M + ("hashrate", "value"), -0.1)]),
        ("fan 101", [(M + ("gpus", 0, "fanPercent"), 101)]),
        ("fan -1", [(M + ("gpus", 0, "fanPercent"), -1)]),
        ("temperature 151", [(M + ("gpus", 0, "temperatureC"), 151)]),
        ("temperature -41", [(M + ("gpus", 0, "temperatureC"), -41)]),
        ("power -1", [(M + ("gpus", 0, "powerW"), -1)]),
        ("gpu index -1", [(M + ("gpus", 0, "index"), -1)]),
        ("gpu index 1.5", [(M + ("gpus", 0, "index"), 1.5)]),
    ]

    # Identity.
    negative += [
        ("machineId with space", [(M + ("machineId",), "rig a")]),
        ("machineId empty", [(M + ("machineId",), "")]),
        ("displayName empty", [(M + ("displayName",), "")]),
        ("sessionId empty", [(M + ("sessionId",), "")]),
        ("sessionId 129 chars", [(M + ("sessionId",), "s" * 129)]),
        ("stop.sessionId empty", [(M + ("stop", "sessionId"), "")]),
        ("duplicate machineId", [(("machines",), [machine, machine])]),
    ]

    # Demo labelling.
    negative += [
        ("demo with null notice", [(("demoNotice",), None)]),
        ("demo with empty notice", [(("demoNotice",), "")]),
        ("live with notice", [(("dataOrigin",), "live")]),
    ]

    # Timestamps: explicit offset, real calendar, no leap second.
    bad_times = [
        "2026-10-24T17:30:00",
        "17:30:00",
        "2026-10-24 17:30:00Z",
        "2026-10-24T17:30:00z",
        "2026-10-24T17:30:00+8:00",
        "2026-10-24T17:30:00+24:00",
        "2026-02-30T00:00:00Z",
        "2025-02-29T00:00:00Z",
        "2026-13-01T00:00:00Z",
        "2026-10-24T24:00:00Z",
        "2026-10-24T23:59:60Z",
        "2026-10-24T09:30:00.Z",
        "2026-10-24T09:30:00.1234567890Z",
        "２026-10-24T09:30:00Z",
        "2026-10-24T09:30:00Z\n",
    ]
    negative += [(f"observedAt {t!r}", [(M + ("observedAt",), t)]) for t in bad_times]
    negative += [
        ("lastAcceptedAt without offset", [(M + ("shares", "lastAcceptedAt"), "2026-10-24T17:29:45")]),
        ("gpu observedAt leap second", [(M + ("gpus", 0, "observedAt"), "2026-10-24T23:59:60+08:00")]),
        ("publishedAt Feb 30", [(("publishedAt",), "2026-02-30T00:00:00Z")]),
    ]

    # Positive: explicit nulls, "unknown", boundaries and valid time forms.
    all_null = [
        (("publishedAt",), None),
        (M + ("worker",), None),
        (M + ("sourceCheckedAt",), None),
        (M + ("sessionId",), None),
        (M + ("sampleSequence",), None),
        (M + ("observedAt",), None),
        (M + ("expectedRunning",), None),
        (M + ("minerRunning", "state"), None),
        (M + ("minerRunning", "observedAt"), None),
        (M + ("hashrate", "value"), None),
        (M + ("hashrate", "unit"), None),
        (M + ("hashrate", "observedAt"), None),
        (M + ("gpus",), None),
        (M + ("shares", "accepted"), None),
        (M + ("shares", "stale"), None),
        (M + ("shares", "rejected"), None),
        (M + ("shares", "observedAt"), None),
        (M + ("shares", "lastAcceptedAt"), None),
    ]
    positive += [
        ("all nullable fields null", all_null),
        ("unknown states", [
            (M + ("expectedRunning",), "unknown"),
            (M + ("minerRunning", "state"), "unknown"),
            (M + ("stop", "reason"), "unknown"),
        ]),
        ("expectedRunning false", [(M + ("expectedRunning",), False)]),
        ("stopped with same-session reason", [
            (M + ("minerRunning", "state"), "stopped"),
            (M + ("stop",), {"reason": "protectionTriggered", "sessionId": "demo-session-0001",
                             "observedAt": "2026-10-24T17:30:00+08:00"}),
        ]),
        ("gpu boundaries", [
            (M + ("gpus", 0, "fanPercent"), 0),
            (M + ("gpus", 1, "fanPercent"), 100),
            (M + ("gpus", 0, "temperatureC"), -40),
            (M + ("gpus", 1, "temperatureC"), 150),
            (M + ("gpus", 0, "powerW"), 0),
        ]),
        ("zero counters and sequence", [
            (M + ("sampleSequence",), 0),
            (M + ("shares", "accepted"), 0),
        ]),
        ("sessionId 128 chars", [(M + ("sessionId",), "s" * 128)]),
        ("empty gpu list", [(M + ("gpus",), [])]),
        ("empty machine list", [(("machines",), [])]),
        ("live with null notice", [(("dataOrigin",), "live"), (("demoNotice",), None)]),
        ("9 fraction digits", [(M + ("observedAt",), "2026-10-24T09:30:00.123456789Z")]),
        ("negative offset", [(M + ("observedAt",), "2026-10-24T04:00:00-05:30")]),
        ("leap day", [(M + ("observedAt",), "2024-02-29T00:00:00Z")]),
    ]

    # Optional earnings extension: the only keys that may be absent (base fixtures omit them).
    market = {"coin": "PRL", "coinUsd": 1.87, "btcUsd": 79646.0, "usdTwd": 32.1,
              "observedAt": "2026-10-24T17:30:00+08:00"}
    earnings = {"coinPerDay": 2.05, "poolHashrate": 1.75e14, "electricityBilled": True,
                "observedAt": "2026-10-24T17:30:00+08:00"}
    positive += [
        ("earnings and market present", [(("market",), market), (M + ("earnings",), earnings)]),
        ("earnings and market null", [(("market",), None), (M + ("earnings",), None)]),
        ("earnings fields null", [(M + ("earnings",), dict.fromkeys(earnings))]),
    ]
    negative += [
        ("market extra key", [(("market",), dict(market, wallet="x"))]),
        ("market missing usdTwd", [(("market",), {k: v for k, v in market.items() if k != "usdTwd"})]),
        ("market negative coin price", [(("market",), dict(market, coinUsd=-1))]),
        ("market zero exchange rate", [(("market",), dict(market, usdTwd=0))]),
        ("market lowercase coin", [(("market",), dict(market, coin="prl"))]),
        ("market as string", [(("market",), "PRL")]),
        ("earnings extra key", [(M + ("earnings",), dict(earnings, account="x"))]),
        ("earnings negative coin per day", [(M + ("earnings",), dict(earnings, coinPerDay=-0.1))]),
        ("earnings billed as string", [(M + ("earnings",), dict(earnings, electricityBilled="yes"))]),
        ("earnings missing observedAt", [(M + ("earnings",), {k: v for k, v in earnings.items() if k != "observedAt"})]),
    ]

    # Optional tariff extension.
    tariff = {"name": "台電簡易型時間電價（二段式）", "effectiveDate": "2025-10-01", "summerPeak": 5.16,
              "summerOffPeak": 2.06, "nonSummerPeak": 4.93, "nonSummerOffPeak": 1.99, "periodsMatch": True,
              "offPeakDates": ["2026-10-26", "2026-12-25"], "observedAt": "2026-10-24T17:30:00+08:00"}
    positive += [
        ("tariff present", [(("tariff",), tariff)]),
        ("tariff null", [(("tariff",), None)]),
        ("tariff no holidays, unknown date", [(("tariff",), dict(tariff, offPeakDates=[], effectiveDate=None, periodsMatch=None))]),
    ]
    negative += [
        ("tariff extra key", [(("tariff",), dict(tariff, url="x"))]),
        ("tariff negative rate", [(("tariff",), dict(tariff, summerPeak=-1))]),
        ("tariff null rate", [(("tariff",), dict(tariff, nonSummerOffPeak=None))]),
        ("tariff bad date", [(("tariff",), dict(tariff, offPeakDates=["2026/10/26"]))]),
        ("tariff too many dates", [(("tariff",), dict(tariff, offPeakDates=["2026-10-26"] * 61))]),
    ]

    # Optional advice extension.
    advice = {"machineId": "demo-laptop", "displayName": "示範筆電", "recommendation": "rest",
              "monthlyNetTwd": 120.5, "startAtTwd": 300, "stopBelowTwd": 250,
              "reason": "估算每月淨收益 NT$120，未達開挖門檻 NT$300", "since": None,
              "observedAt": "2026-10-26T14:30:00+08:00"}
    positive += [
        ("advice present", [(("advice",), [advice, dict(advice, machineId="demo-rig-b", recommendation="mine",
                                                        monthlyNetTwd=-20.5, stopBelowTwd=0,
                                                        since="2026-10-26T14:30:00+08:00")])]),
        ("advice null", [(("advice",), None)]),
        ("advice empty", [(("advice",), [])]),
        ("advice unknown net", [(("advice",), [dict(advice, monthlyNetTwd=None, observedAt=None)])]),
    ]
    negative += [
        ("advice not a list", [(("advice",), advice)]),
        ("advice extra key", [(("advice",), [dict(advice, account="x")])]),
        ("advice unknown recommendation", [(("advice",), [dict(advice, recommendation="maybe")])]),
        ("advice bad machine id", [(("advice",), [dict(advice, machineId="demo laptop")])]),
        ("advice empty reason", [(("advice",), [dict(advice, reason="")])]),
        ("advice null threshold", [(("advice",), [dict(advice, startAtTwd=None)])]),
        ("advice missing since", [(("advice",), [{k: v for k, v in advice.items() if k != "since"}])]),
        ("advice too many", [(("advice",), [advice] * 9)]),
    ]

    # Optional control extension.
    control = {"canStart": False, "canStop": True}
    positive += [
        ("control present", [(M + ("control",), control)]),
        ("control null", [(M + ("control",), None)]),
    ]
    negative += [
        ("control extra key", [(M + ("control",), dict(control, token="x"))]),
        ("control missing canStop", [(M + ("control",), {"canStart": True})]),
        ("control not boolean", [(M + ("control",), dict(control, canStart="yes"))]),
    ]

    # Optional assessment extension.
    assessment = {"light": "green", "title": "挖礦中", "reason": "最後份額 1 分鐘前（平常約 2 分鐘一個）",
                  "observedAt": "2026-10-24T17:30:00+08:00"}
    health = {"uptimeSeconds": 34200, "lastShareAt": "2026-10-24T17:29:00+08:00", "expectedShareSeconds": 120,
              "poolHashrate": 1.5e14, "poolOnline": True, "validSharePercent": 99.6, "maxGpuTemperatureC": 60,
              "temperatureLimitC": 70, "observedAt": "2026-10-24T17:30:00+08:00"}
    positive += [
        ("assessment and health present", [(M + ("assessment",), assessment), (M + ("health",), health)]),
        ("assessment and health null", [(M + ("assessment",), None), (M + ("health",), None)]),
        ("health fields null", [(M + ("health",), dict.fromkeys(health))]),
    ]
    negative += [
        ("assessment unknown light", [(M + ("assessment",), dict(assessment, light="blue"))]),
        ("assessment empty reason", [(M + ("assessment",), dict(assessment, reason=""))]),
        ("assessment reason too long", [(M + ("assessment",), dict(assessment, reason="x" * 201))]),
        ("assessment extra key", [(M + ("assessment",), dict(assessment, token="x"))]),
        ("health extra key", [(M + ("health",), dict(health, pid=1))]),
        ("health percent over 100", [(M + ("health",), dict(health, validSharePercent=101))]),
        ("health zero share interval", [(M + ("health",), dict(health, expectedShareSeconds=0))]),
        ("health missing poolOnline", [(M + ("health",), {k: v for k, v in health.items() if k != "poolOnline"})]),
    ]
    return negative, positive


def main() -> int:
    verbose = "--verbose" in sys.argv
    failures: list[str] = []
    print(f"Python {sys.version.split()[0]} / jsonschema {version('jsonschema')}")

    validator = make_validator()
    print(f"schema: OK against Draft 2020-12 meta-schema ({SCHEMA_PATH.relative_to(ROOT)})")

    fixture_paths = sorted(FIXTURES.glob("*.json"))
    for path in fixture_paths:
        text = path.read_text(encoding="utf-8")
        feed = json.loads(text)
        problems = contract_errors(validator, feed) + demo_label_errors(feed) + privacy_errors(text)
        status = "valid" if not problems else "INVALID"
        print(f"fixture {path.relative_to(ROOT)}: {status}")
        failures += [f"{path.name}: {p}" for p in problems]

    base = json.loads(BASE_FIXTURE.read_text(encoding="utf-8"))
    negative, positive = build_cases(base)

    rejected = 0
    for name, edits in negative:
        errors = contract_errors(validator, apply(base, edits))
        if errors:
            rejected += 1
            if verbose:
                print(f"  rejected as expected: {name} -> {errors[0]}")
        else:
            failures.append(f"negative case accepted: {name}")

    try:
        json.loads(BASE_FIXTURE.read_text(encoding="utf-8")[:-40])
        failures.append("negative case accepted: truncated JSON")
    except json.JSONDecodeError:
        rejected += 1

    accepted = 0
    for name, edits in positive:
        errors = contract_errors(validator, apply(base, edits))
        if errors:
            failures.append(f"positive case rejected: {name}: {errors}")
        else:
            accepted += 1
            if verbose:
                print(f"  accepted as expected: {name}")

    print(f"fixtures: {len(fixture_paths)} checked")
    print(f"negative cases: {rejected}/{len(negative) + 1} rejected")
    print(f"positive cases: {accepted}/{len(positive)} accepted")
    for failure in failures:
        print(f"FAIL {failure}")
    print("RESULT:", "PASS" if not failures else f"FAIL ({len(failures)})")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
