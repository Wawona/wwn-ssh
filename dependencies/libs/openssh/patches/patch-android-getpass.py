#!/usr/bin/env python3
"""Inject SSHPASS/SSH_ASKPASS_PASSWORD getpass shim into OpenSSH for Android."""
from __future__ import annotations

from pathlib import Path

STUB = r"""
/* Android: getpass from SSHPASS / SSH_ASKPASS_PASSWORD */
static char *wwn_android_getpass(const char *prompt) {
    static char passbuf[512];
    const char *env = getenv("SSHPASS");
    if (!env || !env[0])
        env = getenv("SSH_ASKPASS_PASSWORD");
    if (env && env[0]) {
        snprintf(passbuf, sizeof(passbuf), "%s", env);
        return passbuf;
    }
    fprintf(stderr, "wwn-ssh: no SSHPASS/SSH_ASKPASS_PASSWORD for password auth\n");
    passbuf[0] = '\0';
    return passbuf;
}
"""

for rel in ("readpass.c", "sshconnect2.c"):
    p = Path(rel)
    if not p.exists():
        continue
    c = p.read_text()
    if "wwn_android_getpass" in c:
        print(f"{rel} already patched")
        continue
    if "getpass(" not in c:
        continue
    c = c.replace("getpass(", "wwn_android_getpass(", 8)
    marker = '#include "includes.h"'
    if marker in c:
        c = c.replace(marker, marker + "\n" + STUB, 1)
    else:
        c = STUB + c
    p.write_text(c)
    print(f"Patched {rel} for SSHPASS getpass")
