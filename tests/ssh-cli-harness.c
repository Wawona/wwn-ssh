/*
 * Host-side dispatcher for headless CLI matrix against libssh2 CLI sources.
 * Builds as three argv0 siblings (ssh / ssh-keygen / scp) or one binary with
 * WWN_SSH_TOOL=ssh|ssh-keygen|scp.
 */
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int ssh_main(int argc, char *argv[]);
int ssh_keygen_main(int argc, char *argv[]);
int scp_main(int argc, char *argv[]);

static const char *tool_from_argv0(const char *argv0) {
  const char *env = getenv("WWN_SSH_TOOL");
  if (env && env[0])
    return env;
  char buf[512];
  snprintf(buf, sizeof(buf), "%s", argv0 ? argv0 : "ssh");
  return basename(buf);
}

int main(int argc, char *argv[]) {
  const char *tool = tool_from_argv0(argv[0]);
  if (strcmp(tool, "ssh-keygen") == 0)
    return ssh_keygen_main(argc, argv);
  if (strcmp(tool, "scp") == 0)
    return scp_main(argc, argv);
  return ssh_main(argc, argv);
}
