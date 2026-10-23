"""Triage a Unity player/editor log from a DDK project.

Prints: unique exceptions (type + message, count, first DreamscapeLearn/FishNet/UniTask frame, known-benign tag),
ApplicationControlService module results (every Fatal/Error first), ports the player announced, FishNet/LMS
connection-state lines (stack frames filtered out), session milestones (auth, role, seat, avatar), missing
DSL_* variables, [DDK-HOOK] and [DDK-CI] events, and a final VERDICT line.

VERDICT clean = `Module EnvironmentManagement initialized` present, no ACS Fatal/Error, no missing DSL_* variable,
and every exception is on the known-benign list (references/runtime-config.md, Known-benign log noise).
`Missing DSL variables: none` alone proves nothing: a player whose variable system died (F-29) can print it.
Editor/build logs get VERDICT no-player-boot; read their [DDK-CI] `exit` event instead.

Usage: python -I ddk_log_triage.py <unity.log> [--json] [--max 40] [--strict]
Exit: 0 report printed (with --strict: only when VERDICT is clean), 1 VERDICT issues under --strict, 2 log unreadable.
"""
import argparse
import collections
import json
import pathlib
import re
import sys

ap = argparse.ArgumentParser()
ap.add_argument("log")
ap.add_argument("--json", action="store_true")
ap.add_argument("--max", type=int, default=40)
ap.add_argument("--strict", action="store_true", help="exit 1 unless VERDICT is clean")
a = ap.parse_args()

try:
    lines = pathlib.Path(a.log).read_text(encoding="utf-8", errors="replace").splitlines()
except OSError as exc:
    print(f"cannot read log: {exc}", file=sys.stderr)
    sys.exit(2)

color = re.compile(r"</?color[^>]*>")
exc_re = re.compile(r"^([A-Za-z_][\w.]*(?:Exception|Error))(?::\s*(.*))?$")
frame_re = re.compile(r"(DreamscapeLearn\.[\w.<>`+\-]+|FishNet\.[\w.<>`+\-]+|Cysharp\.[\w.<>`+\-]+|"
                      r"UnityEngine\.XR\.Interaction\.Toolkit\.Samples\.[\w.<>`+\-]+)")
# Unity stack frames: "Ns.Type:Method(args)", "(at path:line)", "(.\Library\...cs[Method:123])".
stack_re = re.compile(r"^(?:\(|at |[\w.<>`+\-]+:[\w.<>`+\-]+\s*\()")
acs_re = re.compile(r"\[ApplicationControlService\|(\w+)\]:\s*(.*)")
var_re = re.compile(r"Variable (DSL_[A-Z0-9_]+) not found")
fish_re = re.compile(r"(Server|Client).{0,40}(Started|Stopped|Starting|Stopping)|Local (server|client) is", re.I)
port_res = {
    "dreamfish_server_port": re.compile(r"Setting the Server Port to (\d+)"),
    "rtc_port": re.compile(r"will start on port (\d+)"),
}
session_re = re.compile(r"Received AuthFormBroadcast from \S+|Assigning role: \w+|\[TransitionSync\] Begin catch-up|"
                        r"Received ClientReady|Assigned Seat \S+ to User .{0,120}|User \S+ assigned to seat \d+ in group \d+|"
                        r"Avatar successfully spawned for user .{0,80}")
ci_re = re.compile(r"\[DDK-CI\] (\{.*\})")
hook_re = re.compile(r"\[DDK-HOOK\] (\{.*\})")
# Known-benign exceptions: (type, first-frame substring or "" for any). Keep in sync with runtime-config.md.
BENIGN = [
    ("ArgumentOutOfRangeException", "XRDeviceSimulatorUI"),  # XRI 3.1.2 sample reads action.controls[0] headless
    ("ObjectDisposedException", "Cysharp.Threading.Tasks.PlayerLoopTimer"),
    ("SocketException", "DefaultHttpTransport.StartListening"),  # 2nd client on one PC: Dream Connect 8085 taken (NW-06, F-33)
]

exceptions = collections.OrderedDict()
acs, fish, ci, hook, session = [], [], [], [], []
ports = collections.defaultdict(list)
missing_vars = collections.Counter()
for i, raw in enumerate(lines):
    line = color.sub("", raw).strip()
    m = exc_re.match(line)
    if m:
        key = (m.group(1), (m.group(2) or "")[:200])
        frame = ""
        for nxt in lines[i + 1:i + 25]:
            if not nxt.strip():
                break  # a blank line ends the log entry; never borrow the next entry's frame
            f = frame_re.search(nxt)
            if f:
                frame = f.group(1)
                break
        e = exceptions.setdefault(key, {"type": key[0], "message": key[1], "count": 0, "first_line": i + 1,
                                        "first_frame": frame, "benign": False})
        e["count"] += 1
        e["benign"] = any(key[0].endswith(t) and s in e["first_frame"] for t, s in BENIGN)
    m = acs_re.search(line)
    if m:
        acs.append({"line": i + 1, "level": m.group(1), "msg": m.group(2)[:200]})
    for v in var_re.findall(line):
        missing_vars[v] += 1
    if not stack_re.match(line):
        if fish_re.search(line) and len(fish) < a.max:
            fish.append({"line": i + 1, "msg": line[:200]})
        s = session_re.search(line)
        if s and len(session) < a.max:
            session.append({"line": i + 1, "msg": s.group(0)[:200]})
        for name, rx in port_res.items():
            p = rx.search(line)
            if p and p.group(1) not in ports[name]:
                ports[name].append(p.group(1))
    m = ci_re.search(line)
    if m:
        ci.append(m.group(1))
    m = hook_re.search(line)
    if m:
        hook.append(m.group(1))

bad_acs = [x for x in acs if x["level"] in ("Fatal", "Error")]
acs_shown = (bad_acs + [x for x in acs if x not in bad_acs and (x["level"] == "Warning" or "initialized" in x["msg"])])
env_ok = any(x["msg"].startswith("Module EnvironmentManagement initialized") for x in acs)
unexpected = [e for e in exceptions.values() if not e["benign"]]
reasons = []
if not env_ok:
    reasons.append("EnvironmentManagement not initialized")
if bad_acs:
    reasons.append(f"{len(bad_acs)} ACS Fatal/Error")
if missing_vars:
    reasons.append(f"{len(missing_vars)} missing DSL variable(s)")
if unexpected:
    reasons.append(f"{len(unexpected)} unexpected exception type(s)")
verdict = "clean" if not reasons else "issues"
if not acs:
    # Editor/build logs never boot ACS; their outcome is in the [DDK-CI] exit event.
    verdict, reasons = "no-player-boot", ["no ApplicationControlService lines: an editor/build log, or the player died before ACS"]

report = {
    "log": a.log,
    "lines": len(lines),
    "exceptions": list(exceptions.values()),
    "acs_modules": acs_shown[: max(a.max, len(bad_acs))],
    "environment_management_initialized": env_ok,
    "ports": dict(ports),
    "missing_dsl_variables": dict(missing_vars),
    "fishnet_state": fish,
    "session": session,
    "ddk_hook": hook,
    "ddk_ci": ci,
    "verdict": verdict,
    "verdict_reasons": reasons,
}
if a.json:
    print(json.dumps(report, indent=2))
else:
    print(f"log={a.log} lines={len(lines)}")
    print(f"\n== {len(exceptions)} unique exceptions ({len(unexpected)} unexpected)")
    for e in list(exceptions.values())[: a.max]:
        tag = "benign " if e["benign"] else ""
        print(f"  x{e['count']:<4} L{e['first_line']:<6} {tag}{e['type']}: {e['message'][:110]}  @ {e['first_frame']}")
    print("\n== ACS module events (fatal/error first, then warning/initialized)")
    for x in report["acs_modules"]:
        print(f"  L{x['line']:<6} {x['level']:<8} {x['msg']}")
    print("\n== Ports announced:", dict(ports) or "none")
    print("\n== Missing DSL variables:", dict(missing_vars) or "none")
    print("\n== FishNet state lines")
    for x in fish:
        print(f"  L{x['line']:<6} {x['msg']}")
    if session:
        print("\n== Session milestones")
        for x in session:
            print(f"  L{x['line']:<6} {x['msg']}")
    if hook:
        print("\n== DDK-HOOK events")
        for h in hook:
            print("  " + h[:200])
    if ci:
        print("\n== DDK-CI events")
        for c in ci:
            print("  " + c[:200])
    print(f"\nVERDICT: {verdict}" + (f" ({'; '.join(reasons)})" if reasons else ""))
sys.exit(1 if (a.strict and verdict != "clean") else 0)
