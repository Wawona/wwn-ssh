/*
 * ssh_keygen_main — OpenSSH-shaped keygen for Apple mobile (OpenSSL 3).
 * ed25519 / ecdsa / rsa; OpenSSH-format private + .pub (GPG-export compatible).
 */
#include "wwn_ssh_common.h"
#include "openssh_key_format.h"

#include <openssl/evp.h>
#include <openssl/err.h>
#include <openssl/rsa.h>
#include <openssl/ec.h>
#include <sys/stat.h>
#include <unistd.h>

static void usage(FILE *o) {
  fprintf(o,
          "usage: ssh-keygen [-t ed25519|ecdsa|rsa] [-b bits] [-f outfile]\n"
          "                  [-N new_passphrase] [-C comment] [-y] [-l] [-E hash]\n"
          "                  [-q] [-h|--help] [-V|--version]\n"
          "\n"
          "Wawona Apple-mobile ssh-keygen (OpenSSL).\n"
          "  empty -N  → openssh-key-v1 (gpg --export-ssh-key compatible)\n"
          "  -N pass   → encrypted PKCS#8 PEM (libssh2 / OpenSSH -i)\n"
          "Types: ed25519, ecdsa, rsa. Import GPG SSH keys via Settings or\n"
          "copy `gpg --export-ssh-key` output into Documents/ssh/.\n");
}

static int do_fingerprint(EVP_PKEY *pkey) {
  char tmp[] = "/tmp/wwn-ssh-fp-XXXXXX";
  int fd = mkstemp(tmp);
  if (fd < 0)
    return 1;
  close(fd);
  FILE *m = fopen(tmp, "w+");
  if (!m || wwn_openssh_write_public(m, pkey, NULL) != 0) {
    if (m)
      fclose(m);
    unlink(tmp);
    return 1;
  }
  rewind(m);
  char buf[4096];
  size_t buflen = fread(buf, 1, sizeof(buf), m);
  fclose(m);
  unlink(tmp);
  unsigned char md[EVP_MAX_MD_SIZE];
  unsigned int mdlen = 0;
  EVP_Digest(buf, buflen, md, &mdlen, EVP_sha256(), NULL);
  printf("%u SHA256:", (unsigned)EVP_PKEY_bits(pkey));
  for (unsigned i = 0; i < mdlen; i++)
    printf("%02x", md[i]);
  printf("\n");
  return 0;
}

int ssh_keygen_main(int argc, char *argv[]) {
  const char *type = "ed25519";
  int bits = 0;
  const char *outfile = "id_ed25519";
  const char *pass = "";
  const char *comment = "wawona";
  int quiet = 0;
  int do_pub = 0;
  int do_fp = 0;

  for (int i = 1; i < argc; i++) {
    if (wwn_ssh_is_help(argv[i])) {
      usage(stdout);
      return 0;
    }
    if (wwn_ssh_is_version(argv[i])) {
      fprintf(stderr, "%s\n", WWN_SSH_CLI_VERSION);
      return 0;
    }
    if (strcmp(argv[i], "-t") == 0 && i + 1 < argc)
      type = argv[++i];
    else if (strcmp(argv[i], "-b") == 0 && i + 1 < argc)
      bits = atoi(argv[++i]);
    else if (strcmp(argv[i], "-f") == 0 && i + 1 < argc)
      outfile = argv[++i];
    else if (strcmp(argv[i], "-N") == 0 && i + 1 < argc)
      pass = argv[++i];
    else if (strcmp(argv[i], "-C") == 0 && i + 1 < argc)
      comment = argv[++i];
    else if (strcmp(argv[i], "-y") == 0)
      do_pub = 1;
    else if (strcmp(argv[i], "-l") == 0)
      do_fp = 1;
    else if (strcmp(argv[i], "-E") == 0 && i + 1 < argc)
      (void)argv[++i];
    else if (strcmp(argv[i], "-q") == 0)
      quiet = 1;
    else if (argv[i][0] == '-') {
      fprintf(stderr, "ssh-keygen: unsupported option %s\n", argv[i]);
      usage(stderr);
      return 2;
    }
  }

  if (do_pub || do_fp) {
    EVP_PKEY *pkey = wwn_openssh_load_private(outfile, pass);
    if (!pkey) {
      fprintf(stderr, "ssh-keygen: failed to load %s\n", outfile);
      return 1;
    }
    int rc = 0;
    if (do_fp)
      rc = do_fingerprint(pkey);
    if (rc == 0 && do_pub) {
      if (wwn_openssh_write_public(stdout, pkey, comment) != 0)
        rc = 1;
    }
    EVP_PKEY_free(pkey);
    return rc;
  }

  int id = EVP_PKEY_ED25519;
  if (strcmp(type, "rsa") == 0)
    id = EVP_PKEY_RSA;
  else if (strcmp(type, "ecdsa") == 0)
    id = EVP_PKEY_EC;
  else if (strcmp(type, "ed25519") != 0) {
    fprintf(stderr, "ssh-keygen: unknown key type %s\n", type);
    return 1;
  }

  EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(id, NULL);
  EVP_PKEY *pkey = NULL;
  if (!ctx || EVP_PKEY_keygen_init(ctx) <= 0) {
    fprintf(stderr, "ssh-keygen: keygen init failed\n");
    return 1;
  }
  if (id == EVP_PKEY_RSA) {
    if (bits <= 0)
      bits = 3072;
    EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, bits);
  } else if (id == EVP_PKEY_EC) {
    if (bits <= 0)
      bits = 256;
    EVP_PKEY_CTX_set_ec_paramgen_curve_nid(
        ctx, bits >= 521 ? NID_secp521r1
                         : bits >= 384 ? NID_secp384r1
                                       : NID_X9_62_prime256v1);
  }
  if (EVP_PKEY_keygen(ctx, &pkey) <= 0 || !pkey) {
    fprintf(stderr, "ssh-keygen: generation failed\n");
    EVP_PKEY_CTX_free(ctx);
    return 1;
  }
  EVP_PKEY_CTX_free(ctx);

  FILE *pf = fopen(outfile, "wb");
  if (!pf) {
    fprintf(stderr, "ssh-keygen: cannot write %s: %s\n", outfile, strerror(errno));
    EVP_PKEY_free(pkey);
    return 1;
  }
  if (wwn_openssh_write_private(pf, pkey, comment, pass) != 0) {
    fclose(pf);
    unlink(outfile);
    fprintf(stderr, "ssh-keygen: OpenSSH private encode failed\n");
    ERR_print_errors_fp(stderr);
    EVP_PKEY_free(pkey);
    return 1;
  }
  fclose(pf);
  chmod(outfile, 0600);

  char pubpath[1024];
  snprintf(pubpath, sizeof(pubpath), "%s.pub", outfile);
  FILE *pubf = fopen(pubpath, "wb");
  if (!pubf || wwn_openssh_write_public(pubf, pkey, comment) != 0) {
    if (pubf)
      fclose(pubf);
    fprintf(stderr, "ssh-keygen: OpenSSH public encode failed\n");
    EVP_PKEY_free(pkey);
    return 1;
  }
  fclose(pubf);
  chmod(pubpath, 0644);

  if (!quiet)
    fprintf(stderr,
            "Generating public/private %s key pair.\n"
            "Your identification has been saved in %s\n"
            "Your public key has been saved in %s\n",
            type, outfile, pubpath);
  EVP_PKEY_free(pkey);
  return 0;
}
