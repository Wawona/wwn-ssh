/*
 * Minimal OpenSSH key format (openssh-key-v1) for Apple-mobile ssh-keygen.
 * nixpkgs OpenSSL 3.x no longer ships SSH encoders; we serialize ourselves.
 */
#include "openssh_key_format.h"

#include <openssl/bio.h>
#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/core_names.h>
#include <openssl/objects.h>
#include <openssl/param_build.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>

#include <arpa/inet.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

typedef struct {
  unsigned char *data;
  size_t len;
  size_t cap;
} wbuf;

static int wbuf_reserve(wbuf *b, size_t n) {
  if (b->len + n <= b->cap)
    return 0;
  size_t nc = b->cap ? b->cap * 2 : 256;
  while (nc < b->len + n)
    nc *= 2;
  unsigned char *p = realloc(b->data, nc);
  if (!p)
    return -1;
  b->data = p;
  b->cap = nc;
  return 0;
}

static int wbuf_put(wbuf *b, const void *p, size_t n) {
  if (wbuf_reserve(b, n) != 0)
    return -1;
  memcpy(b->data + b->len, p, n);
  b->len += n;
  return 0;
}

static int wbuf_put_u32(wbuf *b, uint32_t v) {
  uint32_t be = htonl(v);
  return wbuf_put(b, &be, 4);
}

static int wbuf_put_string(wbuf *b, const void *p, size_t n) {
  if (wbuf_put_u32(b, (uint32_t)n) != 0)
    return -1;
  return wbuf_put(b, p, n);
}

static int wbuf_put_cstring(wbuf *b, const char *s) {
  return wbuf_put_string(b, s, s ? strlen(s) : 0);
}

static void wbuf_free(wbuf *b) {
  free(b->data);
  memset(b, 0, sizeof(*b));
}

static int b64_write(FILE *fp, const unsigned char *in, size_t inlen) {
  BIO *b64 = BIO_new(BIO_f_base64());
  BIO *mem = BIO_new(BIO_s_mem());
  if (!b64 || !mem) {
    BIO_free(b64);
    BIO_free(mem);
    return -1;
  }
  BIO_push(b64, mem);
  BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
  if (BIO_write(b64, in, (int)inlen) != (int)inlen || BIO_flush(b64) != 1) {
    BIO_free_all(b64);
    return -1;
  }
  char *ptr = NULL;
  long len = BIO_get_mem_data(mem, &ptr);
  /* OpenSSH wraps at 70 cols */
  for (long i = 0; i < len; i += 70) {
    long n = len - i;
    if (n > 70)
      n = 70;
    if (fwrite(ptr + i, 1, (size_t)n, fp) != (size_t)n || fputc('\n', fp) == EOF) {
      BIO_free_all(b64);
      return -1;
    }
  }
  BIO_free_all(b64);
  return 0;
}

static int encode_ed25519_pub(wbuf *pub, EVP_PKEY *pkey) {
  unsigned char raw[32];
  size_t len = sizeof(raw);
  if (EVP_PKEY_get_raw_public_key(pkey, raw, &len) != 1 || len != 32)
    return -1;
  if (wbuf_put_cstring(pub, "ssh-ed25519") != 0)
    return -1;
  return wbuf_put_string(pub, raw, 32);
}

static int encode_ed25519_priv(wbuf *sec, EVP_PKEY *pkey, uint32_t check,
                               const char *comment) {
  unsigned char pub[32], seed[32], sk[64];
  size_t publen = 32, seedlen = 32;
  if (EVP_PKEY_get_raw_public_key(pkey, pub, &publen) != 1 || publen != 32)
    return -1;
  if (EVP_PKEY_get_raw_private_key(pkey, seed, &seedlen) != 1 || seedlen != 32)
    return -1;
  memcpy(sk, seed, 32);
  memcpy(sk + 32, pub, 32);
  if (wbuf_put_u32(sec, check) != 0 || wbuf_put_u32(sec, check) != 0)
    return -1;
  if (wbuf_put_cstring(sec, "ssh-ed25519") != 0)
    return -1;
  if (wbuf_put_string(sec, pub, 32) != 0)
    return -1;
  if (wbuf_put_string(sec, sk, 64) != 0)
    return -1;
  if (wbuf_put_cstring(sec, comment ? comment : "") != 0)
    return -1;
  /* pad to 8 */
  unsigned char pad = 1;
  while (sec->len % 8 != 0) {
    if (wbuf_put(sec, &pad, 1) != 0)
      return -1;
    pad++;
  }
  return 0;
}

static int encode_rsa_pub(wbuf *pub, EVP_PKEY *pkey) {
  BIGNUM *n = NULL, *e = NULL;
  if (EVP_PKEY_get_bn_param(pkey, OSSL_PKEY_PARAM_RSA_N, &n) != 1)
    EVP_PKEY_get_bn_param(pkey, "n", &n);
  if (EVP_PKEY_get_bn_param(pkey, OSSL_PKEY_PARAM_RSA_E, &e) != 1)
    EVP_PKEY_get_bn_param(pkey, "e", &e);
  if (!n || !e) {
    BN_free(n);
    BN_free(e);
    return -1;
  }
  int nl = BN_num_bytes(n), el = BN_num_bytes(e);
  unsigned char *nb = malloc((size_t)nl + 1);
  unsigned char *eb = malloc((size_t)el + 1);
  int rc = -1;
  if (!nb || !eb)
    goto out;
  /* positive mpint: leading 0 if high bit set */
  nb[0] = 0;
  BN_bn2bin(n, nb + 1);
  size_t nlen = (size_t)nl + ((nb[1] & 0x80) ? 1 : 0);
  const unsigned char *np = (nb[1] & 0x80) ? nb : nb + 1;
  eb[0] = 0;
  BN_bn2bin(e, eb + 1);
  size_t elen = (size_t)el + ((eb[1] & 0x80) ? 1 : 0);
  const unsigned char *ep = (eb[1] & 0x80) ? eb : eb + 1;
  if (wbuf_put_cstring(pub, "ssh-rsa") != 0)
    goto out;
  if (wbuf_put_string(pub, ep, elen) != 0)
    goto out;
  if (wbuf_put_string(pub, np, nlen) != 0)
    goto out;
  rc = 0;
out:
  free(nb);
  free(eb);
  BN_free(n);
  BN_free(e);
  return rc;
}

static int put_mpint(wbuf *b, const BIGNUM *bn) {
  int nl = BN_num_bytes(bn);
  unsigned char *tmp = malloc((size_t)nl + 1);
  if (!tmp)
    return -1;
  tmp[0] = 0;
  BN_bn2bin(bn, tmp + 1);
  size_t len = (size_t)nl + ((nl > 0 && (tmp[1] & 0x80)) ? 1 : 0);
  const unsigned char *p = (nl > 0 && (tmp[1] & 0x80)) ? tmp : tmp + 1;
  if (nl == 0) {
    p = tmp;
    len = 1; /* zero */
    tmp[0] = 0;
  }
  int rc = wbuf_put_string(b, p, len);
  free(tmp);
  return rc;
}

static int encode_rsa_priv(wbuf *sec, EVP_PKEY *pkey, uint32_t check,
                           const char *comment) {
  BIGNUM *n = NULL, *e = NULL, *d = NULL, *iqmp = NULL, *p = NULL, *q = NULL;
  /* Param names vary; try OpenSSL 3 names then fall back. */
  if (EVP_PKEY_get_bn_param(pkey, OSSL_PKEY_PARAM_RSA_N, &n) != 1)
    EVP_PKEY_get_bn_param(pkey, "n", &n);
  if (EVP_PKEY_get_bn_param(pkey, OSSL_PKEY_PARAM_RSA_E, &e) != 1)
    EVP_PKEY_get_bn_param(pkey, "e", &e);
  if (EVP_PKEY_get_bn_param(pkey, OSSL_PKEY_PARAM_RSA_D, &d) != 1)
    EVP_PKEY_get_bn_param(pkey, "d", &d);
  if (EVP_PKEY_get_bn_param(pkey, OSSL_PKEY_PARAM_RSA_FACTOR1, &p) != 1)
    EVP_PKEY_get_bn_param(pkey, "rsa-factor1", &p);
  if (EVP_PKEY_get_bn_param(pkey, OSSL_PKEY_PARAM_RSA_FACTOR2, &q) != 1)
    EVP_PKEY_get_bn_param(pkey, "rsa-factor2", &q);
  if (EVP_PKEY_get_bn_param(pkey, OSSL_PKEY_PARAM_RSA_COEFFICIENT1, &iqmp) != 1)
    EVP_PKEY_get_bn_param(pkey, "rsa-coefficient", &iqmp);
  if (!n || !e || !d || !p || !q) {
    BN_free(n); BN_free(e); BN_free(d); BN_free(p); BN_free(q); BN_free(iqmp);
    return -1;
  }
  if (!iqmp) {
    /* crt coefficient = q^-1 mod p */
    iqmp = BN_mod_inverse(NULL, q, p, NULL);
    if (!iqmp) {
      BN_free(n); BN_free(e); BN_free(d); BN_free(p); BN_free(q);
      return -1;
    }
  }
  int rc = -1;
  if (wbuf_put_u32(sec, check) != 0 || wbuf_put_u32(sec, check) != 0)
    goto out;
  if (wbuf_put_cstring(sec, "ssh-rsa") != 0)
    goto out;
  if (put_mpint(sec, n) != 0 || put_mpint(sec, e) != 0 || put_mpint(sec, d) != 0 ||
      put_mpint(sec, iqmp) != 0 || put_mpint(sec, p) != 0 || put_mpint(sec, q) != 0)
    goto out;
  if (wbuf_put_cstring(sec, comment ? comment : "") != 0)
    goto out;
  unsigned char pad = 1;
  while (sec->len % 8 != 0) {
    if (wbuf_put(sec, &pad, 1) != 0)
      goto out;
    pad++;
  }
  rc = 0;
out:
  BN_free(n);
  BN_free(e);
  BN_free(d);
  BN_free(iqmp);
  BN_free(p);
  BN_free(q);
  return rc;
}

static const char *ec_ssh_name(int nid) {
  switch (nid) {
  case NID_X9_62_prime256v1:
    return "nistp256";
  case NID_secp384r1:
    return "nistp384";
  case NID_secp521r1:
    return "nistp521";
  default:
    return NULL;
  }
}

static const char *ec_keytype(int nid) {
  switch (nid) {
  case NID_X9_62_prime256v1:
    return "ecdsa-sha2-nistp256";
  case NID_secp384r1:
    return "ecdsa-sha2-nistp384";
  case NID_secp521r1:
    return "ecdsa-sha2-nistp521";
  default:
    return NULL;
  }
}

static int ec_nid(EVP_PKEY *pkey) {
  char name[64] = {0};
  size_t namelen = sizeof(name);
  if (EVP_PKEY_get_utf8_string_param(pkey, "group", name, sizeof(name),
                                     &namelen) != 1)
    return NID_undef;
  return OBJ_txt2nid(name);
}

static int encode_ec_pub(wbuf *pub, EVP_PKEY *pkey) {
  int nid = ec_nid(pkey);
  const char *curve = ec_ssh_name(nid);
  const char *kt = ec_keytype(nid);
  if (!curve || !kt)
    return -1;
  size_t publen = 0;
  if (EVP_PKEY_get_octet_string_param(pkey, "pub", NULL, 0, &publen) != 1 ||
      publen == 0)
    return -1;
  unsigned char *raw = malloc(publen);
  if (!raw ||
      EVP_PKEY_get_octet_string_param(pkey, "pub", raw, publen, &publen) != 1) {
    free(raw);
    return -1;
  }
  int rc = -1;
  if (wbuf_put_cstring(pub, kt) != 0)
    goto out;
  if (wbuf_put_cstring(pub, curve) != 0)
    goto out;
  if (wbuf_put_string(pub, raw, publen) != 0)
    goto out;
  rc = 0;
out:
  free(raw);
  return rc;
}

static int encode_ec_priv(wbuf *sec, EVP_PKEY *pkey, uint32_t check,
                          const char *comment) {
  int nid = ec_nid(pkey);
  const char *curve = ec_ssh_name(nid);
  const char *kt = ec_keytype(nid);
  if (!curve || !kt)
    return -1;
  size_t publen = 0;
  if (EVP_PKEY_get_octet_string_param(pkey, "pub", NULL, 0, &publen) != 1)
    return -1;
  unsigned char *raw = malloc(publen);
  BIGNUM *priv = NULL;
  if (!raw ||
      EVP_PKEY_get_octet_string_param(pkey, "pub", raw, publen, &publen) != 1 ||
      EVP_PKEY_get_bn_param(pkey, "priv", &priv) != 1) {
    free(raw);
    BN_free(priv);
    return -1;
  }
  int rc = -1;
  if (wbuf_put_u32(sec, check) != 0 || wbuf_put_u32(sec, check) != 0)
    goto out;
  if (wbuf_put_cstring(sec, kt) != 0 || wbuf_put_cstring(sec, curve) != 0)
    goto out;
  if (wbuf_put_string(sec, raw, publen) != 0)
    goto out;
  if (put_mpint(sec, priv) != 0)
    goto out;
  if (wbuf_put_cstring(sec, comment ? comment : "") != 0)
    goto out;
  unsigned char pad = 1;
  while (sec->len % 8 != 0) {
    if (wbuf_put(sec, &pad, 1) != 0)
      goto out;
    pad++;
  }
  rc = 0;
out:
  free(raw);
  BN_free(priv);
  return rc;
}

int wwn_openssh_write_private(FILE *fp, EVP_PKEY *pkey, const char *comment,
                              const char *pass) {
  (void)comment;
  /* Passphrase: PKCS#8 encrypted PEM (libssh2 + OpenSSH -i compatible).
   * Empty passphrase: classic openssh-key-v1 (gpg --export-ssh-key shape). */
  if (pass && pass[0]) {
    BIO *bio = BIO_new_fp(fp, BIO_NOCLOSE);
    if (!bio)
      return -1;
    int ok = PEM_write_bio_PrivateKey(bio, pkey, EVP_aes_256_cbc(),
                                      (unsigned char *)pass, (int)strlen(pass),
                                      NULL, NULL);
    BIO_free(bio);
    if (!ok) {
      fprintf(stderr, "ssh-keygen: encrypted PKCS#8 encode failed\n");
      ERR_print_errors_fp(stderr);
      return -1;
    }
    return 0;
  }
  wbuf pub = {0}, sec = {0}, blob = {0};
  uint32_t check = 0;
  if (RAND_bytes((unsigned char *)&check, sizeof(check)) != 1)
    check = 0xA5A5A5A5u;
  int id = EVP_PKEY_id(pkey);
  int rc = -1;
  if (id == EVP_PKEY_ED25519) {
    if (encode_ed25519_pub(&pub, pkey) != 0 ||
        encode_ed25519_priv(&sec, pkey, check, comment) != 0)
      goto out;
  } else if (id == EVP_PKEY_RSA) {
    if (encode_rsa_pub(&pub, pkey) != 0 ||
        encode_rsa_priv(&sec, pkey, check, comment) != 0)
      goto out;
  } else if (id == EVP_PKEY_EC) {
    if (encode_ec_pub(&pub, pkey) != 0 ||
        encode_ec_priv(&sec, pkey, check, comment) != 0)
      goto out;
  } else {
    fprintf(stderr, "ssh-keygen: unsupported key type for OpenSSH encode\n");
    goto out;
  }

  /* openssh-key-v1\0 + none/none + nkeys + pubkey + enc */
  if (wbuf_put(&blob, "openssh-key-v1", 15) != 0) /* includes NUL */
    goto out;
  if (wbuf_put_cstring(&blob, "none") != 0 ||
      wbuf_put_cstring(&blob, "none") != 0 ||
      wbuf_put_string(&blob, "", 0) != 0)
    goto out;
  if (wbuf_put_u32(&blob, 1) != 0)
    goto out;
  if (wbuf_put_string(&blob, pub.data, pub.len) != 0)
    goto out;
  if (wbuf_put_string(&blob, sec.data, sec.len) != 0)
    goto out;

  fputs("-----BEGIN OPENSSH PRIVATE KEY-----\n", fp);
  if (b64_write(fp, blob.data, blob.len) != 0)
    goto out;
  fputs("-----END OPENSSH PRIVATE KEY-----\n", fp);
  rc = 0;
out:
  wbuf_free(&pub);
  wbuf_free(&sec);
  wbuf_free(&blob);
  return rc;
}

int wwn_openssh_write_public(FILE *fp, EVP_PKEY *pkey, const char *comment) {
  wbuf pub = {0};
  int id = EVP_PKEY_id(pkey);
  int rc = -1;
  if (id == EVP_PKEY_ED25519) {
    if (encode_ed25519_pub(&pub, pkey) != 0)
      goto out;
  } else if (id == EVP_PKEY_RSA) {
    if (encode_rsa_pub(&pub, pkey) != 0)
      goto out;
  } else if (id == EVP_PKEY_EC) {
    if (encode_ec_pub(&pub, pkey) != 0)
      goto out;
  } else
    goto out;

  BIO *b64 = BIO_new(BIO_f_base64());
  BIO *mem = BIO_new(BIO_s_mem());
  if (!b64 || !mem) {
    BIO_free(b64);
    BIO_free(mem);
    goto out;
  }
  BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
  BIO_push(b64, mem);
  BIO_write(b64, pub.data, (int)pub.len);
  BIO_flush(b64);
  char *ptr = NULL;
  long len = BIO_get_mem_data(mem, &ptr);
  /* key type is first ssh-string inside pub */
  const char *kt = "ssh-ed25519";
  if (id == EVP_PKEY_RSA)
    kt = "ssh-rsa";
  else if (id == EVP_PKEY_EC)
    kt = ec_keytype(ec_nid(pkey));
  fprintf(fp, "%s %.*s", kt, (int)len, ptr);
  if (comment && comment[0])
    fprintf(fp, " %s", comment);
  fputc('\n', fp);
  BIO_free_all(b64);
  rc = 0;
out:
  wbuf_free(&pub);
  return rc;
}

static int r_u32(const unsigned char **p, size_t *left, uint32_t *out) {
  if (*left < 4)
    return -1;
  memcpy(out, *p, 4);
  *out = ntohl(*out);
  *p += 4;
  *left -= 4;
  return 0;
}

static int r_string(const unsigned char **p, size_t *left, const unsigned char **s,
                    size_t *slen) {
  uint32_t n = 0;
  if (r_u32(p, left, &n) != 0 || *left < n)
    return -1;
  *s = *p;
  *slen = n;
  *p += n;
  *left -= n;
  return 0;
}

static EVP_PKEY *parse_openssh_private(const unsigned char *blob, size_t bloblen) {
  if (bloblen < 15 || memcmp(blob, "openssh-key-v1", 15) != 0)
    return NULL;
  const unsigned char *p = blob + 15;
  size_t left = bloblen - 15;
  const unsigned char *s = NULL;
  size_t slen = 0;
  if (r_string(&p, &left, &s, &slen) != 0)
    return NULL; /* cipher */
  if (slen != 4 || memcmp(s, "none", 4) != 0)
    return NULL; /* encrypted unsupported */
  if (r_string(&p, &left, &s, &slen) != 0)
    return NULL; /* kdf */
  if (r_string(&p, &left, &s, &slen) != 0)
    return NULL; /* kdfoptions */
  uint32_t nkeys = 0;
  if (r_u32(&p, &left, &nkeys) != 0 || nkeys != 1)
    return NULL;
  if (r_string(&p, &left, &s, &slen) != 0)
    return NULL; /* public blob (skip) */
  if (r_string(&p, &left, &s, &slen) != 0)
    return NULL; /* secret */
  const unsigned char *sp = s;
  size_t sleft = slen;
  uint32_t c1 = 0, c2 = 0;
  if (r_u32(&sp, &sleft, &c1) != 0 || r_u32(&sp, &sleft, &c2) != 0 || c1 != c2)
    return NULL;
  if (r_string(&sp, &sleft, &s, &slen) != 0)
    return NULL; /* keytype */
  char kt[64];
  if (slen >= sizeof(kt))
    return NULL;
  memcpy(kt, s, slen);
  kt[slen] = 0;

  if (strcmp(kt, "ssh-ed25519") == 0) {
    const unsigned char *pub = NULL, *sk = NULL;
    size_t publen = 0, sklen = 0;
    if (r_string(&sp, &sleft, &pub, &publen) != 0 || publen != 32)
      return NULL;
    if (r_string(&sp, &sleft, &sk, &sklen) != 0 || sklen != 64)
      return NULL;
    return EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, NULL, sk, 32);
  }
  if (strcmp(kt, "ssh-rsa") == 0) {
    const unsigned char *nb = NULL, *eb = NULL, *db = NULL, *iq = NULL, *pb = NULL,
                        *qb = NULL;
    size_t nl = 0, el = 0, dl = 0, iql = 0, pl = 0, ql = 0;
    if (r_string(&sp, &sleft, &nb, &nl) != 0 ||
        r_string(&sp, &sleft, &eb, &el) != 0 ||
        r_string(&sp, &sleft, &db, &dl) != 0 ||
        r_string(&sp, &sleft, &iq, &iql) != 0 ||
        r_string(&sp, &sleft, &pb, &pl) != 0 ||
        r_string(&sp, &sleft, &qb, &ql) != 0)
      return NULL;
    BIGNUM *n = BN_bin2bn(nb, (int)nl, NULL);
    BIGNUM *e = BN_bin2bn(eb, (int)el, NULL);
    BIGNUM *d = BN_bin2bn(db, (int)dl, NULL);
    BIGNUM *iqmp = BN_bin2bn(iq, (int)iql, NULL);
    BIGNUM *pbn = BN_bin2bn(pb, (int)pl, NULL);
    BIGNUM *qbn = BN_bin2bn(qb, (int)ql, NULL);
    EVP_PKEY *pkey = NULL;
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_from_name(NULL, "RSA", NULL);
    OSSL_PARAM_BLD *bld = OSSL_PARAM_BLD_new();
    if (ctx && bld && n && e && d && pbn && qbn && iqmp &&
        OSSL_PARAM_BLD_push_BN(bld, "n", n) &&
        OSSL_PARAM_BLD_push_BN(bld, "e", e) &&
        OSSL_PARAM_BLD_push_BN(bld, "d", d) &&
        OSSL_PARAM_BLD_push_BN(bld, "rsa-factor1", pbn) &&
        OSSL_PARAM_BLD_push_BN(bld, "rsa-factor2", qbn) &&
        OSSL_PARAM_BLD_push_BN(bld, "rsa-coefficient", iqmp) &&
        EVP_PKEY_fromdata_init(ctx) > 0) {
      OSSL_PARAM *params = OSSL_PARAM_BLD_to_param(bld);
      if (params)
        EVP_PKEY_fromdata(ctx, &pkey, EVP_PKEY_KEYPAIR, params);
      OSSL_PARAM_free(params);
    }
    OSSL_PARAM_BLD_free(bld);
    EVP_PKEY_CTX_free(ctx);
    BN_free(n);
    BN_free(e);
    BN_free(d);
    BN_free(iqmp);
    BN_free(pbn);
    BN_free(qbn);
    return pkey;
  }
  /* ECDSA: keytype, curve, pub, priv mpint */
  if (strncmp(kt, "ecdsa-sha2-", 11) == 0) {
    const unsigned char *curve = NULL, *pub = NULL, *priv = NULL;
    size_t cl = 0, publen = 0, privlen = 0;
    if (r_string(&sp, &sleft, &curve, &cl) != 0 ||
        r_string(&sp, &sleft, &pub, &publen) != 0 ||
        r_string(&sp, &sleft, &priv, &privlen) != 0)
      return NULL;
    int nid = NID_X9_62_prime256v1;
    if (cl == 8 && memcmp(curve, "nistp384", 8) == 0)
      nid = NID_secp384r1;
    else if (cl == 8 && memcmp(curve, "nistp521", 8) == 0)
      nid = NID_secp521r1;
    EC_KEY *ec = EC_KEY_new_by_curve_name(nid);
    if (!ec)
      return NULL;
    const EC_GROUP *g = EC_KEY_get0_group(ec);
    EC_POINT *pt = EC_POINT_new(g);
    BIGNUM *k = BN_bin2bn(priv, (int)privlen, NULL);
    if (!pt || !k ||
        EC_POINT_oct2point(g, pt, pub, publen, NULL) != 1 ||
        EC_KEY_set_public_key(ec, pt) != 1 || EC_KEY_set_private_key(ec, k) != 1) {
      EC_POINT_free(pt);
      BN_free(k);
      EC_KEY_free(ec);
      return NULL;
    }
    EC_POINT_free(pt);
    BN_free(k);
    EVP_PKEY *pkey = EVP_PKEY_new();
    if (!pkey || EVP_PKEY_assign_EC_KEY(pkey, ec) != 1) {
      EVP_PKEY_free(pkey);
      EC_KEY_free(ec);
      return NULL;
    }
    return pkey;
  }
  return NULL;
}

EVP_PKEY *wwn_openssh_load_private(const char *path, const char *pass) {
  FILE *fp = fopen(path, "rb");
  if (!fp)
    return NULL;
  fseek(fp, 0, SEEK_END);
  long sz = ftell(fp);
  fseek(fp, 0, SEEK_SET);
  if (sz <= 0 || sz > 1 << 20) {
    fclose(fp);
    return NULL;
  }
  char *text = malloc((size_t)sz + 1);
  if (!text || fread(text, 1, (size_t)sz, fp) != (size_t)sz) {
    free(text);
    fclose(fp);
    return NULL;
  }
  text[sz] = 0;
  fclose(fp);

  EVP_PKEY *pkey = NULL;
  if (strstr(text, "BEGIN OPENSSH PRIVATE KEY")) {
    char *start = strstr(text, "BEGIN OPENSSH PRIVATE KEY-----");
    if (start) {
      start = strchr(start, '\n');
      if (start)
        start++;
    }
    char *end = start ? strstr(start, "-----END") : NULL;
    if (start && end) {
      BIO *b64 = BIO_new(BIO_f_base64());
      BIO *mem = BIO_new_mem_buf(start, (int)(end - start));
      if (b64 && mem) {
        BIO_push(b64, mem);
        unsigned char *bin = malloc(65536);
        int n = bin ? BIO_read(b64, bin, 65536) : -1;
        if (n > 0)
          pkey = parse_openssh_private(bin, (size_t)n);
        free(bin);
        BIO_free_all(b64);
      } else {
        BIO_free(b64);
        BIO_free(mem);
      }
    }
  }
  if (!pkey) {
    BIO *bio = BIO_new_mem_buf(text, (int)sz);
    pkey = PEM_read_bio_PrivateKey(bio, NULL, NULL,
                                   pass && pass[0] ? (void *)pass : NULL);
    BIO_free(bio);
  }
  free(text);
  return pkey;
}
