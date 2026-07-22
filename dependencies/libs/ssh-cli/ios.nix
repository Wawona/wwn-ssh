{
  lib,
  pkgs,
  buildPackages,
  common,
  buildModule,
  simulator ? false,
  iosToolchain,
  toolchainSrc ? null,
}:

# Apple-mobile in-process SSH CLI (libssh2 + OpenSSL).
# Exports ssh_main / ssh_keygen_main / scp_main for wawona-dispatch.
# Never OpenSSH — App Store path.

let
  xcodeUtils = iosToolchain;
  platformInfo = import "${toolchainSrc}/dependencies/toolchains/apple-mobile-platform.nix";
  mobile = platformInfo { inherit iosToolchain simulator; };
  isVisionOS = mobile.isVisionOS;
  mobileMinVersion = mobile.minVersion;
  libssh2 = buildModule.buildForIOS "libssh2" { inherit simulator; };
  openssl = buildModule.buildForIOS "openssl" { inherit simulator; };
  srcRoot = ./src;
in
pkgs.stdenv.mkDerivation {
  name = "wwn-ssh-cli-ios";
  src = srcRoot;
  __noChroot = true;
  nativeBuildInputs = [ ];
  buildInputs = [ libssh2 openssl ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    ${xcodeUtils.mkIOSBuildEnv {
      inherit simulator;
      minVersion = mobileMinVersion;
    }}
    unset MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET
    export NIX_CFLAGS_COMPILE=""
    export NIX_LDFLAGS=""

    CC="$XCODE_CLANG"
    CFLAGS="-arch $IOS_ARCH -target $APPLE_LINKER_TARGET -isysroot $SDKROOT ${
      if isVisionOS then "" else "$APPLE_DEPLOYMENT_FLAG"
    } -fPIC -O2 -I${libssh2}/include -I${openssl}/include"
    for f in ssh_main.c ssh_keygen_main.c scp_main.c openssh_key_format.c; do
      echo "Compiling $f"
      $CC $CFLAGS -c "$src/$f" -o "''${f%.c}.o"
    done
    "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/libtool" -static \
      -o libwwn-ssh-cli.a ssh_main.o ssh_keygen_main.o scp_main.o openssh_key_format.o
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib $out/include
    cp libwwn-ssh-cli.a $out/lib/
    cp $src/wwn_ssh_common.h $out/include/
    # Sentinel for consumers / CI
    nm -gU $out/lib/libwwn-ssh-cli.a | grep -E ' _ssh_main$| _ssh_keygen_main$| _scp_main$' || {
      echo "ERROR: missing ssh_*_main exports"
      nm -gU $out/lib/libwwn-ssh-cli.a || true
      exit 1
    }
    echo "wwn-ssh-cli installed: $out/lib/libwwn-ssh-cli.a"
    runHook postInstall
  '';

  dontFixup = true;
  meta.description = "Wawona libssh2 SSH CLI (ssh/ssh-keygen/scp) for Apple mobile";
}
