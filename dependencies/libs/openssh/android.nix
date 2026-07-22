{
  lib,
  pkgs,
  buildPackages,
  common,
  buildModule,
  androidToolchain,
  ...
}:

# Android / Wear OS SSH backend: OpenSSH portable (not Dropbear).
# Ships ssh, ssh-keygen, scp for jniLibs exec + waypipe --ssh-bin.
# Native streamlocal-forward@openssh.com (no Dropbear -R patch).

let
  versions = import ../ssh-versions.nix;
  NDK_SYSROOT = "${androidToolchain.androidNdkToolchainBase}/sysroot";
  NDK_ZLIB_LIB = "${NDK_SYSROOT}/usr/lib/aarch64-linux-android";
  openssl = buildModule.buildForAndroid "openssl" { };
in
pkgs.stdenv.mkDerivation {
  name = "openssh-android-${versions.opensshPortable.version}";
  version = versions.opensshPortable.version;

  src = pkgs.fetchurl {
    url = versions.opensshPortable.urlAlt;
    sha256 = versions.opensshPortable.sha256;
  };

  nativeBuildInputs = with buildPackages; [
    autoconf
    automake
    pkg-config
    python3
  ];

  buildInputs = [ openssl ];

  postPatch = ''
    # Bionic lacks getpass(); honor SSHPASS / SSH_ASKPASS_PASSWORD for non-TTY.
    python3 ${./patches/patch-android-getpass.py}
    # Use a memset-based explicit_bzero: Bionic's decl is API-gated, and the
    # stock openbsd-compat copy calls undeclared bzero under NDK clang.
    cat > openbsd-compat/explicit_bzero.c <<'EOF'
/* wwn-ssh Android: portable explicit_bzero (no bzero dependency). */
#include "includes.h"
#include <string.h>

void
explicit_bzero(void *p, size_t n)
{
	volatile unsigned char *vp = (volatile unsigned char *)p;
	while (n--) {
		*vp++ = 0;
	}
}
EOF
  '';

  preConfigure = ''
    export CC="${androidToolchain.androidCC}"
    export AR="${androidToolchain.androidAR}"
    export RANLIB="${androidToolchain.androidRANLIB}"
    export STRIP="${androidToolchain.androidSTRIP}"
    export PKG_CONFIG_PATH="${openssl}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    # -Wno-error: OpenSSL 3 deprecations must not fail the client build.
    export CFLAGS="-fPIC -DANDROID -I${openssl}/include -I${NDK_SYSROOT}/usr/include -Wno-error -Wno-deprecated-declarations"
    export LDFLAGS="-L${openssl}/lib -L${androidToolchain.androidNdkAbiLibDir} -L${NDK_ZLIB_LIB}"
    export LIBS="-lssl -lcrypto -lz"
  '';

  configurePhase = ''
    runHook preConfigure
    if [ ! -f configure ]; then
      autoreconf -fi || true
    fi

    export ac_cv_func_setresuid=no
    export ac_cv_func_setresgid=no
    export ac_cv_func_getentropy=no
    # Always use openbsd-compat explicit_bzero (postPatch). Forcing Bionic's
    # HAVE_EXPLICIT_BZERO left sshkey.c with an undeclared call (API gate).
    export ac_cv_func_explicit_bzero=no
    export ac_cv_have_decl_explicit_bzero=no
    export ac_cv_func_bzero=yes
    export ac_cv_have_decl_bzero=yes
    export ac_cv_func_strlcpy=yes
    export ac_cv_func_strlcat=yes
    export ac_cv_func_basename=yes
    export ac_cv_func_dirname=yes
    export ac_cv_func_getpwnam_r=yes
    export ac_cv_func_getpwuid_r=yes
    export ac_cv_func_getgrouplist=no
    export ac_cv_have_decl_HOWMANY=no
    # Do not use Bionic "getrrsetbyname" — it lacks OpenBSD struct rrsetinfo.
    # Build our stub (SSHFP DNS unused for app client).
    export ac_cv_func_getrrsetbyname=no
    export ac_cv_have_decl_getrrsetbyname=no
    # Bionic has openpty/login_tty (API 23+); skip conflicting compat copies.
    export ac_cv_func_openpty=yes
    export ac_cv_have_decl_openpty=yes
    export ac_cv_func_login_tty=yes
    export ac_cv_have_decl_login_tty=yes
    # Cross-compile often mis-detects GCC attributes; Bionic needs real ones
    # or unistd.h __sentinel__ prototypes explode.
    export gcc_cv_attribute=yes
    export gcc_cv_attribute_sentinel=yes

    ./configure \
      --prefix=$out \
      --host=aarch64-linux-android \
      --with-ssl-dir=${openssl} \
      --with-zlib=${NDK_SYSROOT}/usr \
      --without-stackprotect \
      --disable-strip \
      --disable-etc-default-login \
      --disable-lastlog \
      --disable-utmp \
      --disable-utmpx \
      --disable-wtmp \
      --disable-wtmpx \
      --disable-pututline \
      --disable-pututxline \
      --with-pid-dir=/data/local/tmp \
      --with-privsep-path=/data/local/tmp \
      --with-privsep-user=shell \
      --disable-pkcs11 \
      --disable-security-key

    # Cross-configure misses clang attribute probes; without SENTINEL,
    # defines.h empties __sentinel__ and Bionic unistd.h prototypes break.
    # Do not force BOUNDED/NONNULL — they confuse NDK clang parameter attrs.
    echo '#define HAVE_ATTRIBUTE__SENTINEL__ 1' >> config.h
    # Ensure compat explicit_bzero is compiled (never trust cross-detect).
    sed -i.bak 's/^#define HAVE_EXPLICIT_BZERO.*$/#undef HAVE_EXPLICIT_BZERO/' config.h || true
    grep -q '^#undef HAVE_EXPLICIT_BZERO' config.h || echo '#undef HAVE_EXPLICIT_BZERO' >> config.h
    # Drop broken configure remap that turns __res_state into incomplete "state".
    sed -i.bak '/#define __res_state /d' config.h || true
    # Force Bionic helpers so openbsd-compat does not rebuild them.
    for d in HAVE_BZERO HAVE_OPENPTY HAVE_LOGIN_TTY; do
      sed -i.bak "s/^#undef $d$/#define $d 1/" config.h || true
      grep -q "^#define $d" config.h || echo "#define $d 1" >> config.h
    done
    # Replace broken openbsd-compat getrrsetbyname with a no-op (keep headers).
    sed -i.bak 's/^#define HAVE_GETRRSETBYNAME.*$/#undef HAVE_GETRRSETBYNAME/' config.h || true
    grep -q '^#undef HAVE_GETRRSETBYNAME' config.h || echo '#undef HAVE_GETRRSETBYNAME' >> config.h
    cat > openbsd-compat/getrrsetbyname.c <<'EOF'
/* wwn-ssh Android: SSHFP DNS unused; stub (structs live in getrrsetbyname.h). */
#include "includes.h"
#include <errno.h>
#include "getrrsetbyname.h"

int getrrsetbyname(const char *hostname, unsigned int rdclass,
                   unsigned int rdtype, unsigned int flags,
                   struct rrsetinfo **res) {
  (void)hostname; (void)rdclass; (void)rdtype; (void)flags;
  if (res) *res = NULL;
  errno = EAFNOSUPPORT;
  return ERRSET_FAIL;
}
void freerrset(struct rrsetinfo *rrset) { (void)rrset; }
EOF
    # dns.c needs OpenBSD rrsetinfo; Bionic netdb.h lacks it.
    if ! grep -q 'getrrsetbyname.h' dns.c; then
      sed -i.bak '1s|^|#include "openbsd-compat/getrrsetbyname.h"\n|' dns.c
    fi
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    # Client tools only — no sshd needed in the app.
    make -j$NIX_BUILD_CORES \
      ssh scp ssh-keygen ssh-add ssh-agent ssh-keyscan sftp \
      2>&1 || make -j$NIX_BUILD_CORES ssh scp ssh-keygen
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    for t in ssh scp ssh-keygen ssh-add ssh-agent ssh-keyscan sftp; do
      if [ -f "$t" ]; then
        cp -L "$t" "$out/bin/$t"
        chmod +x "$out/bin/$t"
      fi
    done
    test -x $out/bin/ssh
    test -x $out/bin/ssh-keygen
    test -x $out/bin/scp
    echo "openssh-android installed:"
    ls -la $out/bin
    # Version smoke (may fail under qemu absence — still ship binary)
    $out/bin/ssh -V 2>&1 || true
    runHook postInstall
  '';

  dontFixup = true;
  meta = {
    description = "OpenSSH portable client for Android (wwn-ssh)";
    platforms = [ "aarch64-linux" ];
  };
}
