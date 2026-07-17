#!/usr/bin/env python3
"""Prefix OpenSSH globals that collide with libssh2/neovim in Wawona's iOS link."""
from __future__ import annotations

import re
import sys
from pathlib import Path

INCLUDES_MARKER = "WAWONA_OPENSSH_LINK_COLLISION"
INCLUDES_INJECT = """
/* Wawona iOS: redirect call sites; definitions are renamed in log.c/match.c/xmalloc.c. */
#define log_init wwn_openssh_log_init
#define match_user wwn_openssh_match_user
#define xmalloc wwn_openssh_xmalloc
#define xcalloc wwn_openssh_xcalloc
#define xstrdup wwn_openssh_xstrdup
"""

DEFINITION_FILES: list[tuple[str, list[tuple[str, str]]]] = [
    ("log.c", [("log_init", "wwn_openssh_log_init")]),
    ("match.c", [("match_user", "wwn_openssh_match_user")]),
    ("openbsd-compat/xmalloc.c", [
        ("xmalloc", "wwn_openssh_xmalloc"),
        ("xcalloc", "wwn_openssh_xcalloc"),
        ("xstrdup", "wwn_openssh_xstrdup"),
    ]),
]


def rename_definitions(text: str, pairs: list[tuple[str, str]]) -> str:
    for old, new in pairs:
        # Function definitions only (avoid rewriting macro-expanded call sites).
        text = re.sub(
            rf"^(\s*)([A-Za-z_][\w\s\*]*\s+){re.escape(old)}\s*\(",
            rf"\1\2{new}(",
            text,
            flags=re.MULTILINE,
        )
    return text


def patch_includes(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if INCLUDES_MARKER in text:
        return False
    anchor = "#endif /* INCLUDES_H */"
    if anchor not in text:
        anchor = "#endif"
    if anchor not in text:
        raise SystemExit("includes.h end anchor missing")
    inject = f"/* {INCLUDES_MARKER} */{INCLUDES_INJECT}\n{anchor}"
    path.write_text(text.replace(anchor, inject, 1), encoding="utf-8")
    return True


def main() -> int:
    changed = 0
    includes = Path("includes.h")
    if not includes.is_file():
        raise SystemExit("includes.h missing")
    if patch_includes(includes):
        changed += 1
        print("patched includes.h", file=sys.stderr)

    for rel, pairs in DEFINITION_FILES:
        path = Path(rel)
        if not path.is_file():
            print(f"warning: {rel} missing; skipping", file=sys.stderr)
            continue
        original = path.read_text(encoding="utf-8")
        patched = rename_definitions(original, pairs)
        if patched != original:
            path.write_text(patched, encoding="utf-8")
            changed += 1
            print(f"patched {rel}", file=sys.stderr)

    if changed == 0:
        print("no openssh link-collision patches applied", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
