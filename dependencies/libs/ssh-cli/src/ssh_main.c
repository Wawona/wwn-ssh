/*
 * ssh_main — OpenSSH-shaped client for Apple mobile via libssh2.
 */
#include "wwn_ssh_common.h"

#include <libssh2.h>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <ctype.h>

static void usage(FILE *o) {
  fprintf(o,
          "usage: ssh [-46Vv] [-p port] [-l login_name] [-i identity_file]\n"
          "           [-o option] [-t|-T] [user@]hostname [command]\n"
          "\n"
          "%s\n"
          "App Store path: in-process libssh2 (never OpenSSH).\n"
          "Password: SSHPASS or SSH_ASKPASS_PASSWORD or WAYPIPE_SSH_PASSWORD.\n"
          "Keys: OpenSSH-format files (incl. gpg --export-ssh-key).\n",
          WWN_SSH_CLI_VERSION);
}

static int waitsocket(int socket_fd, LIBSSH2_SESSION *session) {
  struct timeval timeout;
  fd_set fd;
  fd_set *writefd = NULL;
  fd_set *readfd = NULL;
  int dir;
  timeout.tv_sec = 10;
  timeout.tv_usec = 0;
  FD_ZERO(&fd);
  FD_SET(socket_fd, &fd);
  dir = libssh2_session_block_directions(session);
  if (dir & LIBSSH2_SESSION_BLOCK_INBOUND)
    readfd = &fd;
  if (dir & LIBSSH2_SESSION_BLOCK_OUTBOUND)
    writefd = &fd;
  return select(socket_fd + 1, readfd, writefd, NULL, &timeout);
}

static const char *password_env(void) {
  const char *p = getenv("SSHPASS");
  if (p && p[0])
    return p;
  p = getenv("SSH_KEY_PASSPHRASE");
  if (p && p[0])
    return p;
  p = getenv("WAYPIPE_SSH_KEY_PASSPHRASE");
  if (p && p[0])
    return p;
  p = getenv("SSH_ASKPASS_PASSWORD");
  if (p && p[0])
    return p;
  p = getenv("WAYPIPE_SSH_PASSWORD");
  if (p && p[0])
    return p;
  return NULL;
}

static int tcp_connect(const char *host, const char *port) {
  struct addrinfo hints, *res = NULL, *rp;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  int rc = getaddrinfo(host, port, &hints, &res);
  if (rc != 0) {
    fprintf(stderr, "ssh: getaddrinfo: %s\n", gai_strerror(rc));
    return -1;
  }
  int sock = -1;
  for (rp = res; rp; rp = rp->ai_next) {
    sock = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
    if (sock < 0)
      continue;
    if (connect(sock, rp->ai_addr, rp->ai_addrlen) == 0)
      break;
    close(sock);
    sock = -1;
  }
  freeaddrinfo(res);
  if (sock < 0)
    fprintf(stderr, "ssh: connect to %s port %s failed\n", host, port);
  return sock;
}

int ssh_main(int argc, char *argv[]) {
  const char *port = "22";
  const char *user = getenv("USER");
  if (!user || !user[0])
    user = "mobile";
  const char *identity = NULL;
  int verbose = 0;
  int force_tty = 0;
  int no_tty = 0;
  const char *host = NULL;
  const char *command = NULL;
  int cmd_start = -1;

  for (int i = 1; i < argc; i++) {
    if (wwn_ssh_is_help(argv[i])) {
      usage(stdout);
      return 0;
    }
    if (wwn_ssh_is_version(argv[i])) {
      fprintf(stderr, "%s\n", WWN_SSH_CLI_VERSION);
      return 0;
    }
    if (strcmp(argv[i], "-p") == 0 && i + 1 < argc) {
      port = argv[++i];
    } else if (strcmp(argv[i], "-l") == 0 && i + 1 < argc) {
      user = argv[++i];
    } else if (strcmp(argv[i], "-i") == 0 && i + 1 < argc) {
      identity = argv[++i];
    } else if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "-vv") == 0 ||
               strcmp(argv[i], "-vvv") == 0) {
      verbose++;
    } else if (strcmp(argv[i], "-t") == 0) {
      force_tty = 1;
    } else if (strcmp(argv[i], "-T") == 0) {
      no_tty = 1;
    } else if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
      i++; /* accept and ignore OpenSSH -o for compatibility */
    } else if (strcmp(argv[i], "-4") == 0 || strcmp(argv[i], "-6") == 0 ||
               strcmp(argv[i], "-q") == 0 || strcmp(argv[i], "-n") == 0) {
      /* accepted */
    } else if (strcmp(argv[i], "--") == 0) {
      continue;
    } else if (argv[i][0] == '-') {
      fprintf(stderr, "ssh: unsupported option %s\n", argv[i]);
      usage(stderr);
      return 2;
    } else if (!host) {
      host = argv[i];
      const char *at = strchr(host, '@');
      if (at && at > host) {
        static char userbuf[256];
        size_t ulen = (size_t)(at - host);
        if (ulen >= sizeof(userbuf))
          ulen = sizeof(userbuf) - 1;
        memcpy(userbuf, host, ulen);
        userbuf[ulen] = '\0';
        user = userbuf;
        host = at + 1;
      }
    } else {
      cmd_start = i;
      break;
    }
  }

  if (!host) {
    usage(stderr);
    return 2;
  }

  if (libssh2_init(0) != 0) {
    fprintf(stderr, "ssh: libssh2_init failed\n");
    return 1;
  }

  int sock = tcp_connect(host, port);
  if (sock < 0) {
    libssh2_exit();
    return 255;
  }

  LIBSSH2_SESSION *session = libssh2_session_init();
  if (!session) {
    close(sock);
    libssh2_exit();
    return 1;
  }
  libssh2_session_set_blocking(session, 1);
  if (verbose)
    libssh2_trace(session, LIBSSH2_TRACE_TRANS | LIBSSH2_TRACE_AUTH);

  int rc = libssh2_session_handshake(session, sock);
  if (rc) {
    fprintf(stderr, "ssh: handshake failed (%d)\n", rc);
    libssh2_session_free(session);
    close(sock);
    libssh2_exit();
    return 255;
  }

  const char *pass = password_env();
  int authed = 0;
  if (identity && identity[0]) {
    char pub[1024];
    snprintf(pub, sizeof(pub), "%s.pub", identity);
    rc = libssh2_userauth_publickey_fromfile(session, user, pub, identity,
                                             pass ? pass : "");
    if (rc == 0)
      authed = 1;
    else if (verbose)
      fprintf(stderr, "ssh: publickey auth failed (%d), trying password\n", rc);
  }
  if (!authed && pass) {
    rc = libssh2_userauth_password(session, user, pass);
    if (rc == 0)
      authed = 1;
  }
  if (!authed) {
    fprintf(stderr, "ssh: Permission denied (publickey,password).\n");
    libssh2_session_disconnect(session, "auth failed");
    libssh2_session_free(session);
    close(sock);
    libssh2_exit();
    return 255;
  }

  LIBSSH2_CHANNEL *channel = libssh2_channel_open_session(session);
  if (!channel) {
    fprintf(stderr, "ssh: channel open failed\n");
    libssh2_session_free(session);
    close(sock);
    libssh2_exit();
    return 255;
  }

  if (force_tty && !no_tty)
    libssh2_channel_request_pty(channel, "xterm-256color");

  if (cmd_start >= 0) {
    size_t len = 0;
    for (int i = cmd_start; i < argc; i++)
      len += strlen(argv[i]) + 1;
    char *cmd = malloc(len + 1);
    if (!cmd)
      return 1;
    cmd[0] = '\0';
    for (int i = cmd_start; i < argc; i++) {
      if (i > cmd_start)
        strcat(cmd, " ");
      strcat(cmd, argv[i]);
    }
    rc = libssh2_channel_exec(channel, cmd);
    free(cmd);
  } else {
    rc = libssh2_channel_shell(channel);
  }
  if (rc) {
    fprintf(stderr, "ssh: failed to start remote command/shell\n");
    libssh2_channel_free(channel);
    libssh2_session_free(session);
    close(sock);
    libssh2_exit();
    return 255;
  }

  char buf[4096];
  for (;;) {
    rc = libssh2_channel_read(channel, buf, sizeof(buf));
    if (rc > 0) {
      fwrite(buf, 1, (size_t)rc, stdout);
      fflush(stdout);
    } else if (rc == LIBSSH2_ERROR_EAGAIN) {
      waitsocket(sock, session);
    } else {
      break;
    }
    /* also drain stderr */
    rc = libssh2_channel_read_stderr(channel, buf, sizeof(buf));
    if (rc > 0) {
      fwrite(buf, 1, (size_t)rc, stderr);
      fflush(stderr);
    }
    if (libssh2_channel_eof(channel))
      break;
  }

  int exitcode = 0;
  char *exitsignal = NULL;
  libssh2_channel_close(channel);
  libssh2_channel_get_exit_status(channel); /* warm */
  exitcode = (int)libssh2_channel_get_exit_status(channel);
  libssh2_channel_get_exit_signal(channel, &exitsignal, NULL, NULL, NULL, NULL,
                                  NULL);
  libssh2_channel_free(channel);
  libssh2_session_disconnect(session, "Normal Shutdown");
  libssh2_session_free(session);
  close(sock);
  libssh2_exit();
  (void)exitsignal;
  return exitcode;
}
