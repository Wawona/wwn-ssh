#ifndef WWN_OPENSSH_KEY_FORMAT_H
#define WWN_OPENSSH_KEY_FORMAT_H

#include <openssl/evp.h>
#include <stdio.h>

/* Write OpenSSH private key (openssh-key-v1). Empty pass only (cipher none). */
int wwn_openssh_write_private(FILE *fp, EVP_PKEY *pkey, const char *comment,
                              const char *pass);

/* Write OpenSSH one-line public key (ssh-ed25519 / ecdsa / ssh-rsa). */
int wwn_openssh_write_public(FILE *fp, EVP_PKEY *pkey, const char *comment);

/* Load OpenSSH private or PEM/PKCS8 private key. */
EVP_PKEY *wwn_openssh_load_private(const char *path, const char *pass);

#endif
