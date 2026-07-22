#!/usr/bin/env bash
# Headless CLI matrix runner for host OpenSSH or linked harness.
# Usage: run-matrix.sh <target> <ssh-bin-dir-or-harness>
set -euo pipefail
TARGET="${1:?target}"
BIN="${2:?bin dir or harness prefix}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MATRIX="$ROOT/tests/cli-matrix.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export TMP

set +e
python3 - "$MATRIX" "$TARGET" "$BIN" <<'PY'
import json, os, re, subprocess, sys, shlex
from pathlib import Path

matrix, target, bindir = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.loads(Path(matrix).read_text())
tmpdir = os.environ["TMP"]
failed = 0

def expand(s: str) -> str:
    return s.replace("$TMP", tmpdir)

def resolve(tool: str) -> str:
    p = Path(bindir)
    if p.is_file():
        return str(p)
    cand = p / tool
    if cand.exists():
        return str(cand)
    return tool

def exit_ok(rid: str, exp, code: int, combined: str) -> bool:
    if exp is None:
        return True
    if code == exp:
        return True
    # OpenSSH / libssh2: -V may be 0; help often 255 with usage on stderr.
    banner = bool(re.search(r"OpenSSH_|Wawona ssh|usage:", combined, re.I))
    if banner and (
        rid.endswith("version")
        or rid.endswith("-V")
        or "help" in rid
        or rid.endswith("h-short")
    ):
        return True
    return False

done = set()
rows = data["rows"]
for _ in range(5):
    progress = False
    for row in rows:
        rid = row["id"]
        if rid in done:
            continue
        if target not in row.get("targets", []):
            done.add(rid)
            continue
        needs = row.get("needs") or "none"
        if needs not in ("none",):
            print(f"SKIP {rid} (needs={needs})")
            done.add(rid)
            continue
        deps = row.get("dependsOn") or []
        if any(d not in done for d in deps):
            continue
        argv = [expand(a) for a in row["argv"]]
        tool = row["tool"]
        if Path(bindir).is_dir():
            cmd = [str(Path(bindir) / tool)] + argv[1:]
        else:
            cmd = [resolve(tool)] + argv[1:]
        print("+", " ".join(shlex.quote(c) for c in cmd))
        r = subprocess.run(cmd, capture_output=True, text=True)
        combined = (r.stdout or "") + (r.stderr or "")
        exp = row.get("expectExit")
        row_fail = False
        if not exit_ok(rid, exp, r.returncode, combined):
            print(f"FAIL {rid}: exit {r.returncode} expected {exp}")
            print(combined)
            failed += 1
            row_fail = True
        for rx_key in ("expectStdoutRegex", "expectStderrRegex"):
            rx = row.get(rx_key)
            if rx and not re.search(rx, combined, re.I):
                print(f"FAIL {rid}: {rx_key} {rx!r} not in output")
                print(combined)
                failed += 1
                row_fail = True
        for f in row.get("expectFiles") or []:
            if not Path(expand(f)).exists():
                print(f"FAIL {rid}: missing file {f}")
                failed += 1
                row_fail = True
        if not row_fail:
            print(f"OK {rid}")
        done.add(rid)
        progress = True
    if not progress:
        break

pending = [r["id"] for r in rows if r["id"] not in done and target in r.get("targets", [])]
if pending:
    print("UNRESOLVED", pending)
    failed += 1
sys.exit(1 if failed else 0)
PY
rc=$?
set -e
exit "$rc"
