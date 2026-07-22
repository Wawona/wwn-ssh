#!/usr/bin/env python3
"""Fail if cli-matrix.json tools.helpFlags are not referenced by any row argv."""
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    matrix_path = Path(sys.argv[1] if len(sys.argv) > 1 else "tests/cli-matrix.json")
    data = json.loads(matrix_path.read_text())
    rows = data.get("rows", [])
    tools = data.get("tools", {})
    used: dict[str, set[str]] = {t: set() for t in tools}
    for row in rows:
        tool = row.get("tool")
        if tool not in used:
            continue
        for a in row.get("argv", []):
            if isinstance(a, str) and a.startswith("-"):
                used[tool].add(a.split("=")[0])
                # also record long/short pairs loosely
                used[tool].add(a)

    failed = False
    for tool, meta in tools.items():
        required = set(meta.get("helpFlags", []))
        have = used.get(tool, set())
        # A flag is covered if any row argv contains it exactly
        missing = sorted(f for f in required if f not in have)
        # Allow -V covered by --version rows sharing tool via either
        soft = []
        for f in list(missing):
            if f == "--version" and "-V" in have:
                soft.append(f)
            if f == "-V" and "--version" in have:
                soft.append(f)
            if f == "--help" and ("-h" in have or "-?" in have):
                soft.append(f)
            if f == "-h" and "--help" in have:
                soft.append(f)
        missing = [f for f in missing if f not in soft]
        if missing:
            failed = True
            print(f"FAIL {tool}: helpFlags not in any matrix argv: {missing}")
        else:
            print(f"OK {tool}: all helpFlags covered")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
