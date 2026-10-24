#!/usr/bin/env python3
"""Static policy checks for the app source and build configuration (standard library only).

Checks text and plist content only. It is NOT a compile, test or runtime check: it cannot prove the
app builds or behaves as described, only that the source and settings say what they should.

Usage: python -I tools/check_static_policy.py
"""
from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
failures: list[str] = []
passed = 0


def check(condition: bool, message: str) -> None:
    global passed
    if condition:
        passed += 1
    else:
        failures.append(message)


def swift_files(*dirs: str) -> list[Path]:
    return sorted(p for d in dirs for p in (ROOT / d).rglob("*.swift"))


# 1. Info.plist: ATS stays on except local networking; no background modes.
info = plistlib.loads((ROOT / "iOSApp" / "Info.plist").read_bytes())
ats = info.get("NSAppTransportSecurity", {})
check(ats.get("NSAllowsLocalNetworking") is True, "Info.plist: NSAllowsLocalNetworking must be true")
for key in ("NSAllowsArbitraryLoads", "NSAllowsArbitraryLoadsInWebContent", "NSAllowsArbitraryLoadsForMedia",
            "NSExceptionDomains"):
    check(key not in ats, f"Info.plist: {key} must not be set")
check("UIBackgroundModes" not in info, "Info.plist: UIBackgroundModes must not be set (foreground only)")
check(bool(info.get("NSLocalNetworkUsageDescription")), "Info.plist: NSLocalNetworkUsageDescription required")
# SideStore sends CFBundleDisplayName as the Apple App ID name, which rejects non-ASCII text.
check(re.fullmatch(r"[A-Za-z0-9 ]+", info.get("CFBundleDisplayName", "")) is not None,
      "Info.plist: CFBundleDisplayName must be ASCII (SideStore App ID name); localize it instead")
strings = ROOT / "iOSApp" / "zh-Hant.lproj" / "InfoPlist.strings"
check(strings.is_file() and '"CFBundleDisplayName" = "礦機狀態";' in strings.read_text(encoding="utf-8"),
      "zh-Hant.lproj/InfoPlist.strings must give the Chinese home-screen name")

# 2. XcodeGen spec (album-ios layout): iOS 16, core framework target, simulator unit tests,
#    bundled demo fixture, explicit Info.plist, no packages at all.
spec = (ROOT / "project.yml").read_text(encoding="utf-8")
check(not (ROOT / "App" / "project.yml").exists(), "App/project.yml must be gone: project.yml lives at the app root")
check(re.search(r'iOS:\s*"16\.0"', spec) is not None, "project.yml: deployment target must be iOS 16.0")
check(re.search(r"\n  MinerStatusCore:\s*\n\s*type:\s*framework\s*\n", spec) is not None,
      "project.yml: MinerStatusCore must be a framework target")
check(re.search(r"dependencies:\s*\n\s*- target:\s*MinerStatusCore\s*\n", spec) is not None,
      "project.yml: app must depend on the MinerStatusCore target")
check(re.search(r"\n  MinerStatusCoreTests:\s*\n\s*type:\s*bundle\.unit-test\s*\n", spec) is not None,
      "project.yml: MinerStatusCoreTests must be a unit-test bundle")
check(re.search(r"testTargets:\s*\n\s*- MinerStatusCoreTests\s*\n", spec) is not None,
      "project.yml: app scheme must run MinerStatusCoreTests")
check(re.search(r"\n  MinerStatusUITests:\s*\n\s*type:\s*bundle\.ui-testing\s*\n", spec) is not None,
      "project.yml: MinerStatusUITests must be a UI-testing bundle")
check(re.search(r"testTargets:\s*\n\s*- MinerStatusCoreTests\s*\n\s*- MinerStatusUITests\s*\n", spec) is not None,
      "project.yml: app scheme must also run MinerStatusUITests")
check(re.search(r"path:\s*fixtures/demo-running\.json\s*\n\s*buildPhase:\s*resources", spec) is not None,
      "project.yml: demo-running.json must be a bundled resource")
check("INFOPLIST_FILE: iOSApp/Info.plist" in spec, "project.yml: INFOPLIST_FILE must point to iOSApp/Info.plist")
check(re.search(r"^packages:", spec, re.MULTILINE) is None, "project.yml: no package dependencies")
check((ROOT / "fixtures" / "demo-running.json").is_file(), "fixtures/demo-running.json must exist")

# 3. Read-only network surface in shipped code (Sources/ and iOSApp/).
shipped = swift_files("Sources", "iOSApp")
for path in shipped:
    text = path.read_text(encoding="utf-8")
    name = path.relative_to(ROOT)
    for verb in ("POST", "PUT", "PATCH", "DELETE"):
        check(f'"{verb}"' not in text, f"{name}: HTTP {verb} is not allowed")
    for api in ("BGTaskScheduler", "beginBackgroundTask", "UIApplication.shared.open", "WKWebView",
                "NWListener", "URLSessionWebSocketTask", "httpBody"):
        check(api not in text, f"{name}: {api} is not allowed")
    if path.name != "StatusClient.swift":
        check("URLSession" not in text, f"{name}: networking must go through StatusClient.swift")
    # No hardcoded addresses: the only URL-looking literal allowed is the settings placeholder.
    for literal in re.findall(r'"(https?://[^"]*)"', text):
        check(literal == "http://主機名稱:埠/status", f"{name}: hardcoded URL literal {literal!r}")
    check(re.search(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", text) is None, f"{name}: IPv4-like literal")

client = (ROOT / "Sources" / "MinerStatusCore" / "StatusClient.swift").read_text(encoding="utf-8")
check('request.httpMethod = "GET"' in client, "StatusClient.swift: request must be GET")
settings = (ROOT / "iOSApp" / "SourceSettingsView.swift").read_text(encoding="utf-8")
check('@AppStorage("sourceURL") private var urlText = ""' in settings, "settings: source URL must default to empty")
model = (ROOT / "iOSApp" / "AppModel.swift").read_text(encoding="utf-8")
check("@Published private(set) var mode: AppMode = .demo" in model, "AppModel: every launch must start in demo")
check(model.count("startPolling()") >= 2 and "func setForeground" in model,
      "AppModel: polling must be tied to the foreground")

# 4. Tests use only documentation-reserved addresses.
for path in swift_files("Tests"):
    text = path.read_text(encoding="utf-8")
    name = path.relative_to(ROOT)
    for host in re.findall(r"https?://(?:[^@/\"]*@)?([^:/\"]+)", text):
        check(host.lower().endswith(".example") or host.startswith("192.0.2.") or host == "",
              f"{name}: test host {host!r} is not documentation-reserved")
    for ip in re.findall(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", text):
        check(ip.startswith("192.0.2."), f"{name}: IPv4 literal {ip} is not in 192.0.2.0/24")

for failure in failures:
    print(f"FAIL {failure}")
print(f"static policy checks: {passed} passed, {len(failures)} failed")
print("RESULT:", "PASS" if not failures else "FAIL")
sys.exit(0 if not failures else 1)
