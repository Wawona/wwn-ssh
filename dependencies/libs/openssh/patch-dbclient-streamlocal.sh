#!/usr/bin/env bash
# patch-dbclient-streamlocal.sh
#
# Patches Dropbear's dbclient to support -R /remote/path:/local/path
# for Unix socket forwarding via streamlocal-forward@openssh.com.
# This is the same protocol extension OpenSSH uses and is required by waypipe.
#
# Patches: cli-runopts.c, cli-tcpfwd.c, cli-session.c, runopts.h, tcpfwd.h
set -euo pipefail

echo "=== Patching dbclient for client-side streamlocal forwarding ==="

python3 <<'PYEOF'
from pathlib import Path
import re
import sys

errors = []

# ─────────────────────────────────────────────────────────────────────
# 1. tcpfwd.h -- Add StreamLocalFwdEntry struct and declarations
# ─────────────────────────────────────────────────────────────────────
p = Path("src/tcpfwd.h")
c = p.read_text()

addition = """
#if DROPBEAR_CLI_REMOTESTREAMFWD
struct StreamLocalFwdEntry {
\tconst char *remotepath;
\tconst char *localpath;
\tunsigned int have_reply;
};

extern const struct ChanType cli_chan_streamlocal_remote;
void setup_remote_streamlocal(void);
#endif
"""

marker = "#define CHANNEL_ID_TCPFORWARDED"
if "StreamLocalFwdEntry" not in c:
    if marker in c:
        idx = c.index(marker)
        line_end = c.index("\n", idx)
        c = c[:line_end+1] + addition + c[line_end+1:]
        p.write_text(c)
        print("✓ tcpfwd.h: added StreamLocalFwdEntry and declarations")
    else:
        errors.append("tcpfwd.h: could not find CHANNEL_ID_TCPFORWARDED marker")
else:
    print("· tcpfwd.h: already patched")

# ─────────────────────────────────────────────────────────────────────
# 2. runopts.h -- Add remote_streamlocal_fwds to cli_runopts
# ─────────────────────────────────────────────────────────────────────
p = Path("src/runopts.h")
c = p.read_text()

if "remote_streamlocal_fwds" not in c:
    needle = "#if DROPBEAR_CLI_REMOTETCPFWD\n\tm_list * remotefwds;\n#endif"
    replacement = (
        "#if DROPBEAR_CLI_REMOTETCPFWD\n"
        "\tm_list * remotefwds;\n"
        "#endif\n"
        "#if DROPBEAR_CLI_REMOTESTREAMFWD\n"
        "\tm_list * remote_streamlocal_fwds;\n"
        "#endif"
    )
    if needle in c:
        c = c.replace(needle, replacement)
        p.write_text(c)
        print("✓ runopts.h: added remote_streamlocal_fwds")
    else:
        # Try with spaces instead of tabs
        needle2 = "#if DROPBEAR_CLI_REMOTETCPFWD\n m_list * remotefwds;\n#endif"
        if needle2 in c:
            replacement2 = replacement.replace("\t", " ")
            c = c.replace(needle2, replacement2)
            p.write_text(c)
            print("✓ runopts.h: added remote_streamlocal_fwds (space indent)")
        else:
            errors.append("runopts.h: could not find remotefwds field")
else:
    print("· runopts.h: already patched")

# ─────────────────────────────────────────────────────────────────────
# 3. cli-runopts.c -- Add add_streamlocal_fwd(), modify -R handler,
#    initialize list
# ─────────────────────────────────────────────────────────────────────
p = Path("src/cli-runopts.c")
c = p.read_text()

# 3a. Add add_streamlocal_fwd() function after addforward()
new_func = """
#if DROPBEAR_CLI_REMOTESTREAMFWD
static void add_streamlocal_fwd(const char* origstr) {
\tchar *str = m_strdup(origstr);
\tchar *colon = strchr(str, ':');
\tif (!colon || colon == str || colon[1] == '\\0') {
\t\tdropbear_exit("Bad streamlocal forward '%s' (expected remote:path)", origstr);
\t}
\t*colon = '\\0';
\tstruct StreamLocalFwdEntry *newfwd = m_malloc(sizeof(*newfwd));
\tnewfwd->remotepath = str;
\tnewfwd->localpath = colon + 1;
\tnewfwd->have_reply = 0;
\tlist_append(cli_opts.remote_streamlocal_fwds, newfwd);
\tTRACE(("add_streamlocal_fwd: %s -> %s", newfwd->remotepath, newfwd->localpath))
}
#endif
"""

if "add_streamlocal_fwd" not in c:
    # Add forward declaration after addforward declaration
    fwd_decl_needle = "#if DROPBEAR_CLI_ANYTCPFWD\nstatic void addforward(const char* str, m_list *fwdlist);\n#endif"
    fwd_decl_replace = (
        "#if DROPBEAR_CLI_ANYTCPFWD\n"
        "static void addforward(const char* str, m_list *fwdlist);\n"
        "#endif\n"
        "#if DROPBEAR_CLI_REMOTESTREAMFWD\n"
        "static void add_streamlocal_fwd(const char* origstr);\n"
        "#endif"
    )
    if fwd_decl_needle in c:
        c = c.replace(fwd_decl_needle, fwd_decl_replace)
        print("✓ cli-runopts.c: added forward declaration for add_streamlocal_fwd()")
    else:
        errors.append("cli-runopts.c: could not find addforward declaration for forward decl")

    # Insert function body after addforward function
    end_marker = "badport:\n\tdropbear_exit(\"Bad TCP port in '%s'\", origstr);\n}"
    if end_marker not in c:
        end_marker = "badport:\n dropbear_exit(\"Bad TCP port in '%s'\", origstr);\n}"
    if end_marker in c:
        c = c.replace(end_marker, end_marker + new_func)
        print("✓ cli-runopts.c: added add_streamlocal_fwd()")
    else:
        errors.append("cli-runopts.c: could not find addforward end marker")

# 3b. Modify -R handler to detect unix paths
old_handler = (
    '\t\tif (opt == OPT_REMOTETCPFWD) {\n'
    '\t\t\tTRACE(("opt remotetcpfwd"))\n'
    '\t\t\taddforward(&argv[i][j], cli_opts.remotefwds);\n'
    '\t\t}'
)
new_handler = (
    '\t\tif (opt == OPT_REMOTETCPFWD) {\n'
    '\t\t\tTRACE(("opt remotetcpfwd"))\n'
    '#if DROPBEAR_CLI_REMOTESTREAMFWD\n'
    '\t\t\tif (argv[i][j] == \'/\' || argv[i][j] == \'.\') {\n'
    '\t\t\t\tadd_streamlocal_fwd(&argv[i][j]);\n'
    '\t\t\t} else\n'
    '#endif\n'
    '\t\t\taddforward(&argv[i][j], cli_opts.remotefwds);\n'
    '\t\t}'
)
if "add_streamlocal_fwd(&argv" not in c:
    if old_handler in c:
        c = c.replace(old_handler, new_handler)
        print("✓ cli-runopts.c: patched -R handler for streamlocal")
    else:
        errors.append("cli-runopts.c: could not find -R handler pattern")

# 3c. Initialize remote_streamlocal_fwds list
init_needle = "#if DROPBEAR_CLI_REMOTETCPFWD\n\tcli_opts.remotefwds = list_new();\n#endif"
init_replace = (
    "#if DROPBEAR_CLI_REMOTETCPFWD\n"
    "\tcli_opts.remotefwds = list_new();\n"
    "#endif\n"
    "#if DROPBEAR_CLI_REMOTESTREAMFWD\n"
    "\tcli_opts.remote_streamlocal_fwds = list_new();\n"
    "#endif"
)
if "remote_streamlocal_fwds = list_new" not in c:
    if init_needle in c:
        c = c.replace(init_needle, init_replace)
        print("✓ cli-runopts.c: added list initialization")
    else:
        init_needle2 = init_needle.replace("\t", " ")
        init_replace2 = init_replace.replace("\t", " ")
        if init_needle2 in c:
            c = c.replace(init_needle2, init_replace2)
            print("✓ cli-runopts.c: added list initialization (space indent)")
        else:
            errors.append("cli-runopts.c: could not find remotefwds init")

p.write_text(c)

# ─────────────────────────────────────────────────────────────────────
# 4. cli-tcpfwd.c -- Add streamlocal forwarding functions and modify
#    request success/failure handlers
# ─────────────────────────────────────────────────────────────────────
p = Path("src/cli-tcpfwd.c")
c = p.read_text()

# 4a. Add the streamlocal forwarding code at the end of the file
streamlocal_code = """
#if DROPBEAR_CLI_REMOTESTREAMFWD

static int newstreamlocalforwarded(struct Channel *channel);

const struct ChanType cli_chan_streamlocal_remote = {
\t"forwarded-streamlocal@openssh.com",
\tnewstreamlocalforwarded,
\tNULL,
\tNULL,
\tNULL,
\tNULL
};

static void send_msg_global_request_streamlocal(const char *path) {
\tTRACE(("enter send_msg_global_request_streamlocal"))
\tCHECKCLEARTOWRITE();
\tbuf_putbyte(ses.writepayload, SSH_MSG_GLOBAL_REQUEST);
\tbuf_putstring(ses.writepayload, "streamlocal-forward@openssh.com", 31);
\tbuf_putbyte(ses.writepayload, 1); /* want_reply */
\tbuf_putstring(ses.writepayload, path, strlen(path));
\tencrypt_packet();
\tTRACE(("leave send_msg_global_request_streamlocal"))
}

void setup_remote_streamlocal() {
\tm_list_elem *iter;
\tTRACE(("enter setup_remote_streamlocal"))
\tfor (iter = cli_opts.remote_streamlocal_fwds->first; iter; iter = iter->next) {
\t\tstruct StreamLocalFwdEntry *fwd = (struct StreamLocalFwdEntry*)iter->item;
\t\tsend_msg_global_request_streamlocal(fwd->remotepath);
\t}
\tTRACE(("leave setup_remote_streamlocal"))
}

static int newstreamlocalforwarded(struct Channel *channel) {
\tchar *origpath = NULL;
\tunsigned int pathlen;
\tm_list_elem *iter = NULL;
\tstruct StreamLocalFwdEntry *fwd = NULL;
\tint err = SSH_OPEN_ADMINISTRATIVELY_PROHIBITED;

\torigpath = buf_getstring(ses.payload, &pathlen);
\tbuf_eatstring(ses.payload); /* reserved */

\tfor (iter = cli_opts.remote_streamlocal_fwds->first; iter; iter = iter->next) {
\t\tfwd = (struct StreamLocalFwdEntry*)iter->item;
\t\tif (strcmp(origpath, fwd->remotepath) == 0) {
\t\t\tbreak;
\t\t}
\t}

\tif (iter == NULL || fwd == NULL) {
\t\tcleantext(origpath);
\t\tdropbear_log(LOG_INFO, "Server sent unrequested streamlocal forward from \\\"%s\\\"",
\t\t\torigpath);
\t\tgoto out;
\t}

\tchannel->conn_pending = connect_streamlocal(fwd->localpath,
\t\tchannel_connect_done, channel, DROPBEAR_PRIO_NORMAL);
\terr = SSH_OPEN_IN_PROGRESS;

out:
\tm_free(origpath);
\tTRACE(("leave newstreamlocalforwarded: err %d", err))
\treturn err;
}

#endif /* DROPBEAR_CLI_REMOTESTREAMFWD */
"""

if "cli_chan_streamlocal_remote" not in c:
    c += streamlocal_code
    print("✓ cli-tcpfwd.c: added streamlocal forwarding code")

# 4b. Modify cli_recv_msg_request_success to handle streamlocal entries
# Find the closing brace of the function and insert before it
success_func_end = (
    "void cli_recv_msg_request_success() {"
)
if success_func_end in c and "remote_streamlocal_fwds" not in c:
    # Find the function and add streamlocal handling after the TCP loop
    # Match the pattern: the for loop over remotefwds ends, then function closes
    # We need to insert before the final } of the function
    pattern = r"(void cli_recv_msg_request_success\(\) \{.*?)((\n\})\s*\nvoid cli_recv_msg_request_failure)"
    match = re.search(pattern, c, re.DOTALL)
    if match:
        insert_point = match.start(3)
        streamlocal_success = (
            "\n#if DROPBEAR_CLI_REMOTESTREAMFWD\n"
            "\tfor (iter = cli_opts.remote_streamlocal_fwds->first; iter; iter = iter->next) {\n"
            "\t\tstruct StreamLocalFwdEntry *fwd = (struct StreamLocalFwdEntry*)iter->item;\n"
            "\t\tif (!fwd->have_reply) {\n"
            "\t\t\tfwd->have_reply = 1;\n"
            "\t\t\treturn;\n"
            "\t\t}\n"
            "\t}\n"
            "#endif\n"
        )
        c = c[:insert_point] + streamlocal_success + c[insert_point:]
        print("✓ cli-tcpfwd.c: patched cli_recv_msg_request_success")
    else:
        errors.append("cli-tcpfwd.c: could not find request_success function boundary")

# 4c. Modify cli_recv_msg_request_failure similarly
if "remote_streamlocal_fwds" in c:
    # Already partially patched for success; now handle failure
    failure_pattern = r"(void cli_recv_msg_request_failure\(\) \{.*?)((\n\})\s*\n\nvoid setup_remotetcp)"
    match = re.search(failure_pattern, c, re.DOTALL)
    if match:
        insert_point = match.start(3)
        streamlocal_failure = (
            "\n#if DROPBEAR_CLI_REMOTESTREAMFWD\n"
            "\tfor (iter = cli_opts.remote_streamlocal_fwds->first; iter; iter = iter->next) {\n"
            "\t\tstruct StreamLocalFwdEntry *fwd = (struct StreamLocalFwdEntry*)iter->item;\n"
            "\t\tif (!fwd->have_reply) {\n"
            "\t\t\tfwd->have_reply = 1;\n"
            "\t\t\tfwd_failed(\"Remote streamlocal forward request failed (%s -> %s)\",\n"
            "\t\t\t\tfwd->remotepath, fwd->localpath);\n"
            "\t\t\treturn;\n"
            "\t\t}\n"
            "\t}\n"
            "#endif\n"
        )
        c = c[:insert_point] + streamlocal_failure + c[insert_point:]
        print("✓ cli-tcpfwd.c: patched cli_recv_msg_request_failure")
    else:
        errors.append("cli-tcpfwd.c: could not find request_failure function boundary")

p.write_text(c)

# ─────────────────────────────────────────────────────────────────────
# 5. cli-session.c -- Register channel type and call setup
# ─────────────────────────────────────────────────────────────────────
p = Path("src/cli-session.c")
c = p.read_text()

# 5a. Add streamlocal channel type to cli_chantypes[]
old_chantypes = (
    "#if DROPBEAR_CLI_REMOTETCPFWD\n"
    "\t&cli_chan_tcpremote,\n"
    "#endif\n"
    "#if DROPBEAR_CLI_AGENTFWD\n"
    "\t&cli_chan_agent,\n"
    "#endif"
)
new_chantypes = (
    "#if DROPBEAR_CLI_REMOTETCPFWD\n"
    "\t&cli_chan_tcpremote,\n"
    "#endif\n"
    "#if DROPBEAR_CLI_REMOTESTREAMFWD\n"
    "\t&cli_chan_streamlocal_remote,\n"
    "#endif\n"
    "#if DROPBEAR_CLI_AGENTFWD\n"
    "\t&cli_chan_agent,\n"
    "#endif"
)
if "cli_chan_streamlocal_remote" not in c:
    if old_chantypes in c:
        c = c.replace(old_chantypes, new_chantypes)
        print("✓ cli-session.c: registered streamlocal channel type")
    else:
        old2 = old_chantypes.replace("\t", " ")
        new2 = new_chantypes.replace("\t", " ")
        if old2 in c:
            c = c.replace(old2, new2)
            print("✓ cli-session.c: registered streamlocal channel type (space indent)")
        else:
            errors.append("cli-session.c: could not find cli_chantypes array")

# 5b. Call setup_remote_streamlocal() after setup_remotetcp()
old_setup = (
    "#if DROPBEAR_CLI_REMOTETCPFWD\n"
    "\t\t\tsetup_remotetcp();\n"
    "#endif"
)
new_setup = (
    "#if DROPBEAR_CLI_REMOTETCPFWD\n"
    "\t\t\tsetup_remotetcp();\n"
    "#endif\n"
    "#if DROPBEAR_CLI_REMOTESTREAMFWD\n"
    "\t\t\tsetup_remote_streamlocal();\n"
    "#endif"
)
if "setup_remote_streamlocal" not in c:
    if old_setup in c:
        c = c.replace(old_setup, new_setup)
        print("✓ cli-session.c: added setup_remote_streamlocal() call")
    else:
        errors.append("cli-session.c: could not find setup_remotetcp call")

p.write_text(c)

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────
if errors:
    print("\n⚠ ERRORS:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)
else:
    print("\n✓ All Dropbear streamlocal patches applied successfully")

PYEOF

echo "=== Dropbear streamlocal patching complete ==="
