#!/usr/bin/env python3
"""Stub fork/execlp askpass paths in OpenSSH readpass.c for tvOS/watchOS.

Those APIs are __TVOS_PROHIBITED / __WATCHOS_PROHIBITED. In-process Wawona
already supplies passwords via SSH_ASKPASS_PASSWORD / SSHPASS, so askpass
subprocess support is unused on Apple TV / Watch.
"""
from __future__ import annotations

import pathlib
import re
import sys

path = pathlib.Path("readpass.c")
if not path.is_file():
    print("readpass.c missing; skip", file=sys.stderr)
    sys.exit(0)

text = path.read_text()
if "wwn_apple_no_fork_askpass" in text:
    print("readpass.c already stubbed")
    sys.exit(0)

stub = r'''
/* wwn_apple_no_fork_askpass: tvOS/watchOS cannot fork/execlp askpass. */
#if defined(__APPLE__)
#include <TargetConditionals.h>
#if (defined(TARGET_OS_TV) && TARGET_OS_TV) || (defined(TARGET_OS_WATCH) && TARGET_OS_WATCH)
#define WWN_APPLE_NO_ASKPASS_FORK 1
#endif
#endif

#ifdef WWN_APPLE_NO_ASKPASS_FORK
static int
ssh_askpass(char *askpass, const char *msg)
{
	(void)askpass;
	(void)msg;
	errno = ENOTSUP;
	return -1;
}
#else
'''

# Insert stub + #else before first ssh_askpass definition, close with #endif after it.
m = re.search(r"\nstatic int\nssh_askpass\(", text)
if not m:
    m = re.search(r"\nint\nssh_askpass\(", text)
if not m:
    # Some trees use a single-line prototype/definition.
    m = re.search(r"\n(?:static\s+)?int\s+ssh_askpass\s*\(", text)
if not m:
    print("Could not find ssh_askpass in readpass.c", file=sys.stderr)
    sys.exit(1)

# Find the end of ssh_askpass function: next top-level function after its body.
start = m.start()
# Walk braces from the first '{' after match.
brace_at = text.find("{", m.end())
if brace_at < 0:
    print("ssh_askpass has no body", file=sys.stderr)
    sys.exit(1)
depth = 0
i = brace_at
while i < len(text):
    c = text[i]
    if c == "{":
        depth += 1
    elif c == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
    i += 1
else:
    print("unbalanced braces in ssh_askpass", file=sys.stderr)
    sys.exit(1)

original = text[start:end]
replacement = stub + original + "\n#endif /* !WWN_APPLE_NO_ASKPASS_FORK */\n"
path.write_text(text[:start] + replacement + text[end:])
print("✓ Stubbed ssh_askpass fork/execlp for tvOS/watchOS")
