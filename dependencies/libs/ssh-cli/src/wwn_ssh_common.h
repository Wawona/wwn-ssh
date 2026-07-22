#ifndef WWN_SSH_COMMON_H
#define WWN_SSH_COMMON_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#define WWN_SSH_CLI_VERSION "Wawona ssh (libssh2) 1.0.0"

static inline int wwn_ssh_is_help(const char *a) {
  return a && (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0 || strcmp(a, "-?") == 0);
}

static inline int wwn_ssh_is_version(const char *a) {
  return a && (strcmp(a, "-V") == 0 || strcmp(a, "--version") == 0);
}

#endif
