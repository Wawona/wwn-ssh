{
  pkgs,
  ...
}:

# Host-runnable libssh2 CLI for headless matrix (same sources as Apple archive).
# Not a product package — CI only. Apple mobile still ships libwwn-ssh-cli.a.

let
  srcRoot = ./src;
  harnessSrc = ../../../tests/ssh-cli-harness.c;
in
pkgs.stdenv.mkDerivation {
  name = "wwn-ssh-cli-host-harness";
  srcs = [
    srcRoot
    harnessSrc
  ];
  sourceRoot = ".";
  unpackPhase = ''
    runHook preUnpack
    mkdir -p src
    cp -r ${srcRoot}/* src/
    cp ${harnessSrc} ssh-cli-harness.c
    runHook postUnpack
  '';

  buildInputs = [
    pkgs.libssh2
    pkgs.openssl
  ];
  nativeBuildInputs = [ pkgs.pkg-config ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    mkdir -p bin
    for f in ssh_main ssh_keygen_main scp_main openssh_key_format; do
      $CC -O2 -Wall -Wno-deprecated-declarations \
        $(pkg-config --cflags libssh2 openssl) \
        -I./src \
        -c src/$f.c -o $f.o
    done
    $CC -O2 -Wall \
      -I./src \
      -c ssh-cli-harness.c -o harness.o
    $CC -o bin/wwn-ssh-cli-harness harness.o ssh_main.o ssh_keygen_main.o scp_main.o \
      openssh_key_format.o \
      $(pkg-config --libs libssh2 openssl)
    ln -sf wwn-ssh-cli-harness bin/ssh
    ln -sf wwn-ssh-cli-harness bin/ssh-keygen
    ln -sf wwn-ssh-cli-harness bin/scp
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp -a bin/* $out/bin/
    $out/bin/ssh -V 2>&1 | grep -qi 'Wawona ssh' || {
      echo "ERROR: harness ssh -V missing Wawona banner"
      $out/bin/ssh -V 2>&1 || true
      exit 1
    }
    runHook postInstall
  '';

  meta.description = "Host harness for wwn-ssh libssh2 CLI matrix (CI)";
}
