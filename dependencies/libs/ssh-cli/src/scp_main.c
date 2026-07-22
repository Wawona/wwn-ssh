/*
 * scp_main — basic scp via libssh2 SFTP for Apple mobile.
 */
#include "wwn_ssh_common.h"

#include <libssh2.h>
#include <libssh2_sftp.h>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

static void usage(FILE *o) {
  fprintf(o,
          "usage: scp [-v] [-P port] [-i identity_file] source ... target\n"
          "\n"
          "%s\n"
          "Copies via SFTP. Paths may be user@host:path or local paths.\n",
          WWN_SSH_CLI_VERSION);
}

static const char *password_env(void) {
  const char *p = getenv("SSHPASS");
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
  if (getaddrinfo(host, port, &hints, &res) != 0)
    return -1;
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
  return sock;
}

static int parse_remote(const char *spec, char *user, size_t user_sz, char *host,
                        size_t host_sz, char *path, size_t path_sz) {
  const char *colon = strrchr(spec, ':');
  if (!colon || colon == spec)
    return 0;
  const char *at = strchr(spec, '@');
  if (at && at < colon) {
    size_t ulen = (size_t)(at - spec);
    if (ulen >= user_sz)
      ulen = user_sz - 1;
    memcpy(user, spec, ulen);
    user[ulen] = '\0';
    size_t hlen = (size_t)(colon - at - 1);
    if (hlen >= host_sz)
      hlen = host_sz - 1;
    memcpy(host, at + 1, hlen);
    host[hlen] = '\0';
  } else {
    const char *u = getenv("USER");
    snprintf(user, user_sz, "%s", u && u[0] ? u : "mobile");
    size_t hlen = (size_t)(colon - spec);
    if (hlen >= host_sz)
      hlen = host_sz - 1;
    memcpy(host, spec, hlen);
    host[hlen] = '\0';
  }
  snprintf(path, path_sz, "%s", colon + 1);
  return 1;
}

int scp_main(int argc, char *argv[]) {
  const char *port = "22";
  const char *identity = NULL;
  int verbose = 0;
  int argi = 1;
  for (; argi < argc; argi++) {
    if (wwn_ssh_is_help(argv[argi])) {
      usage(stdout);
      return 0;
    }
    if (wwn_ssh_is_version(argv[argi])) {
      fprintf(stderr, "%s\n", WWN_SSH_CLI_VERSION);
      return 0;
    }
    if (strcmp(argv[argi], "-P") == 0 && argi + 1 < argc) {
      port = argv[++argi];
    } else if (strcmp(argv[argi], "-i") == 0 && argi + 1 < argc) {
      identity = argv[++argi];
    } else if (strcmp(argv[argi], "-v") == 0) {
      verbose++;
    } else if (argv[argi][0] == '-') {
      fprintf(stderr, "scp: unsupported option %s\n", argv[argi]);
      return 2;
    } else {
      break;
    }
  }
  if (argc - argi < 2) {
    usage(stderr);
    return 2;
  }
  const char *src = argv[argi];
  const char *dst = argv[argc - 1];
  char user[256], host[256], rpath[1024];
  int src_remote = parse_remote(src, user, sizeof(user), host, sizeof(host),
                                rpath, sizeof(rpath));
  int dst_remote = parse_remote(dst, user, sizeof(user), host, sizeof(host),
                                rpath, sizeof(rpath));
  if (src_remote == dst_remote) {
    fprintf(stderr, "scp: one of source/target must be remote (user@host:path)\n");
    return 2;
  }
  /* Re-parse the remote side for connection details */
  const char *remote_spec = src_remote ? src : dst;
  parse_remote(remote_spec, user, sizeof(user), host, sizeof(host), rpath,
               sizeof(rpath));

  if (libssh2_init(0) != 0)
    return 1;
  int sock = tcp_connect(host, port);
  if (sock < 0) {
    libssh2_exit();
    return 1;
  }
  LIBSSH2_SESSION *session = libssh2_session_init();
  if (!session) {
    close(sock);
    libssh2_exit();
    return 1;
  }
  libssh2_session_set_blocking(session, 1);
  if (libssh2_session_handshake(session, sock)) {
    fprintf(stderr, "scp: handshake failed\n");
    libssh2_session_free(session);
    close(sock);
    libssh2_exit();
    return 1;
  }
  const char *pass = password_env();
  int ok = 0;
  if (identity && identity[0]) {
    char pub[1024];
    snprintf(pub, sizeof(pub), "%s.pub", identity);
    if (libssh2_userauth_publickey_fromfile(session, user, pub, identity,
                                            pass ? pass : "") == 0)
      ok = 1;
  }
  if (!ok && pass &&
      libssh2_userauth_password(session, user, pass) == 0)
    ok = 1;
  if (!ok) {
    fprintf(stderr, "scp: authentication failed\n");
    libssh2_session_free(session);
    close(sock);
    libssh2_exit();
    return 1;
  }
  LIBSSH2_SFTP *sftp = libssh2_sftp_init(session);
  if (!sftp) {
    fprintf(stderr, "scp: sftp init failed\n");
    libssh2_session_free(session);
    close(sock);
    libssh2_exit();
    return 1;
  }

  char buf[8192];
  if (src_remote) {
    /* download */
    LIBSSH2_SFTP_HANDLE *h =
        libssh2_sftp_open(sftp, rpath, LIBSSH2_FXF_READ, 0);
    if (!h) {
      fprintf(stderr, "scp: cannot open remote %s\n", rpath);
      libssh2_sftp_shutdown(sftp);
      libssh2_session_free(session);
      close(sock);
      libssh2_exit();
      return 1;
    }
    FILE *out = fopen(dst, "wb");
    if (!out) {
      fprintf(stderr, "scp: cannot write %s\n", dst);
      libssh2_sftp_close(h);
      return 1;
    }
    for (;;) {
      ssize_t n = libssh2_sftp_read(h, buf, sizeof(buf));
      if (n > 0)
        fwrite(buf, 1, (size_t)n, out);
      else
        break;
    }
    fclose(out);
    libssh2_sftp_close(h);
    if (verbose)
      fprintf(stderr, "scp: downloaded %s -> %s\n", rpath, dst);
  } else {
    /* upload */
    FILE *in = fopen(src, "rb");
    if (!in) {
      fprintf(stderr, "scp: cannot read %s\n", src);
      return 1;
    }
    struct stat st;
    fstat(fileno(in), &st);
    LIBSSH2_SFTP_HANDLE *h = libssh2_sftp_open(
        sftp, rpath,
        LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
        0644);
    if (!h) {
      fprintf(stderr, "scp: cannot open remote %s\n", rpath);
      fclose(in);
      return 1;
    }
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
      size_t off = 0;
      while (off < n) {
        ssize_t w = libssh2_sftp_write(h, buf + off, n - off);
        if (w < 0)
          break;
        off += (size_t)w;
      }
    }
    fclose(in);
    libssh2_sftp_close(h);
    if (verbose)
      fprintf(stderr, "scp: uploaded %s -> %s\n", src, rpath);
    (void)st;
  }

  libssh2_sftp_shutdown(sftp);
  libssh2_session_disconnect(session, "scp done");
  libssh2_session_free(session);
  close(sock);
  libssh2_exit();
  return 0;
}
