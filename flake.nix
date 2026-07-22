{
  description = "wwn-ssh: App-Store-compliant SSH stack. Apple mobile = libssh2 CLI + waypipe transport (never OpenSSH); Android/macOS/Linux = OpenSSH; sshpass where ssh is spawned.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    wwn-toolchain.url = "github:Wawona/wwn-toolchain";
    wwn-toolchain.inputs.nixpkgs.follows = "nixpkgs";
    wwn-toolchain.inputs.rust-overlay.follows = "rust-overlay";
  };

  outputs = { self, nixpkgs, rust-overlay, wwn-toolchain, ... }:
    let
      darwinSystems = [ "x86_64-darwin" "aarch64-darwin" ];
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];
      allSystems = darwinSystems ++ linuxSystems;
      forAll = nixpkgs.lib.genAttrs allSystems;
      inherit (wwn-toolchain.lib) withPlatformVariants baseRegistry mkToolchains;

      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) ];
        config = { allowUnfree = true; allowUnsupportedSystem = true; android_sdk.accept_license = true; };
      };

      mkAndroidSDK = system: pkgs:
        let
          androidConfig = import "${wwn-toolchain}/dependencies/android/sdk-config.nix" {
            inherit system;
            lib = pkgs.lib;
          };
          androidComposition = pkgs.androidenv.composeAndroidPackages {
            cmdLineToolsVersion = "latest";
            platformToolsVersion = "latest";
            buildToolsVersions = [ androidConfig.buildToolsVersion ];
            platformVersions = [ (toString androidConfig.compileSdk) ];
            abiVersions = [ androidConfig.hostEmulatorAbi ];
            systemImageTypes = [ "google_apis_playstore" ];
            includeEmulator = androidConfig.emulatorSupported;
            includeSystemImages = androidConfig.emulatorSupported;
            includeNDK = true;
            includeCmake = true;
            ndkVersions = [ androidConfig.ndkVersion ];
            cmakeVersions = [ androidConfig.cmakeVersion ];
            useGoogleAPIs = false;
          };
          sdkRoot = "${androidComposition.androidsdk}/libexec/android-sdk";
        in {
          androidsdk = androidComposition.androidsdk;
          inherit sdkRoot;
          platformTools = androidComposition.platform-tools;
          cmdlineTools = androidComposition.androidsdk;
          buildTools = "${sdkRoot}/build-tools/${androidConfig.buildToolsVersion}";
          cmake = "${sdkRoot}/cmake/${androidConfig.cmakeVersion}";
          ndk = "${sdkRoot}/ndk/${androidConfig.ndkVersion}";
          emulator =
            if androidConfig.emulatorSupported then
              androidComposition.emulator
            else
              androidComposition.androidsdk;
          systemImage =
            "${sdkRoot}/system-images/android-${toString androidConfig.compileSdk}/google_apis_playstore/${androidConfig.hostEmulatorAbi}";
          androidSdkPackages = { };
          inherit androidConfig;
        };

      versions = import ./dependencies/libs/ssh-versions.nix;
      opensshDir = ./dependencies/libs/openssh;
      libssh2Dir = ./dependencies/libs/libssh2;
      sshpassDir = ./dependencies/libs/sshpass;
      sshCliDir = ./dependencies/libs/ssh-cli;
    in
    {
      registryFragment = {
        # Terminal SSH binary surface (Android/macOS/Linux). Apple mobile = null.
        openssh = withPlatformVariants {
          android = opensshDir + "/android.nix";
          wearos = opensshDir + "/wearos.nix";
          ios = null;
          ipados = null;
          tvos = null;
          visionos = null;
          watchos = null;
          macos = opensshDir + "/macos.nix";
          linux = opensshDir + "/linux.nix";
        };
        # libssh2 + streamlocal for waypipe on Apple mobile (+ Android build).
        libssh2 = withPlatformVariants {
          android = libssh2Dir + "/android.nix";
          wearos = libssh2Dir + "/wearos.nix";
          ios = libssh2Dir + "/ios.nix";
          ipados = libssh2Dir + "/ios.nix";
          tvos = libssh2Dir + "/tvos.nix";
          visionos = libssh2Dir + "/visionos.nix";
          watchos = libssh2Dir + "/watchos.nix";
          macos = null;
        };
        # In-process OpenSSH-shaped CLI for Apple mobile (ssh_main / keygen / scp).
        "ssh-cli" = withPlatformVariants {
          ios = sshCliDir + "/ios.nix";
          ipados = sshCliDir + "/ipados.nix";
          tvos = sshCliDir + "/tvos.nix";
          visionos = sshCliDir + "/visionos.nix";
          watchos = sshCliDir + "/watchos.nix";
          android = null;
          macos = null;
          linux = null;
        };
        sshpass = withPlatformVariants {
          android = sshpassDir + "/android.nix";
          wearos = sshpassDir + "/wearos.nix";
          ios = sshpassDir + "/ios.nix";
          ipados = sshpassDir + "/ios.nix";
          tvos = sshpassDir + "/tvos.nix";
          visionos = sshpassDir + "/visionos.nix";
          watchos = sshpassDir + "/watchos.nix";
          macos = sshpassDir + "/macos.nix";
          linux = sshpassDir + "/linux.nix";
        };
      };

      lib = {
        inherit versions;
        backends = {
          ios = { sshBackend = "libssh2-cli"; waypipeSshTransport = "libssh2-inprocess"; forkExec = false; };
          ipados = { sshBackend = "libssh2-cli"; waypipeSshTransport = "libssh2-inprocess"; forkExec = false; };
          tvos = { sshBackend = "libssh2-cli"; waypipeSshTransport = "libssh2-inprocess"; forkExec = false; };
          watchos = { sshBackend = "libssh2-cli"; waypipeSshTransport = "libssh2-inprocess"; forkExec = false; };
          visionos = { sshBackend = "libssh2-cli"; waypipeSshTransport = "libssh2-inprocess"; forkExec = false; };
          android = { sshBackend = "openssh"; waypipeSshTransport = "exec-ssh"; forkExec = true; };
          wearos = { sshBackend = "openssh"; waypipeSshTransport = "exec-ssh"; forkExec = true; };
          macos = { sshBackend = "openssh"; waypipeSshTransport = "exec-ssh"; forkExec = true; };
          linux = { sshBackend = "openssh"; waypipeSshTransport = "exec-ssh"; forkExec = true; };
        };
        backendFor = platform: self.lib.backends.${platform};
      };

      packages = forAll (system:
        let
          pkgs = pkgsFor system;
          androidSDK = mkAndroidSDK system pkgs;
          androidAllowExperimentalFallback =
            (builtins.getEnv "WAWONA_ANDROID_EXPERIMENTAL_FALLBACK") == "1"
            || builtins.elem system [ "aarch64-darwin" "aarch64-linux" ];
          tc = mkToolchains {
            inherit pkgs androidSDK androidAllowExperimentalFallback;
            pkgsAndroid = pkgs.pkgsCross.aarch64-android;
            registry = baseRegistry // self.registryFragment;
          };
          isDarwin = builtins.elem system darwinSystems;
        in
        {
          openssh-android = tc.buildForAndroid "openssh" { };
          libssh2-android = tc.buildForAndroid "libssh2" { };
          sshpass-android = tc.buildForAndroid "sshpass" { };
          # Host-runnable libssh2 CLI (same sources as Apple archive) for H1 matrix.
          ssh-cli-host = import ./dependencies/libs/ssh-cli/host-harness.nix {
            inherit pkgs;
          };
        } // (if isDarwin then {
          libssh2-ios = tc.buildForIOS "libssh2" { };
          ssh-cli-ios = tc.buildForIOS "ssh-cli" { };
          sshpass-ios = tc.buildForIOS "sshpass" { };
          openssh-macos = tc.buildForMacOS "openssh" { };
          sshpass-macos = tc.buildForMacOS "sshpass" { };
        } else {
          openssh-linux = tc.buildForLinux "openssh" { };
          sshpass-linux = tc.buildForLinux "sshpass" { };
        }));

      checks = forAll (system:
        let
          pkgs = pkgsFor system;
          versions' = versions;
        in {
          versions-pinned = pkgs.runCommand "wwn-ssh-versions-pinned" { } ''
            echo "libssh2=${versions'.libssh2.version}" > $out
            echo "opensshPortable=${versions'.opensshPortable.version}" >> $out
            echo "sshpass=${versions'.sshpass.version}" >> $out
          '';
          backends-no-stub = pkgs.runCommand "wwn-ssh-backends-no-stub" { } ''
            ${pkgs.jq}/bin/jq -e '
              .ios.sshBackend == "libssh2-cli" and
              .android.sshBackend == "openssh" and
              .macos.sshBackend == "openssh"
            ' ${pkgs.writeText "backends.json" (builtins.toJSON self.lib.backends)}
            touch $out
          '';
          help-coverage = pkgs.runCommand "wwn-ssh-help-coverage" {
            nativeBuildInputs = [ pkgs.python3 ];
          } ''
            python3 ${./tests/check-help-coverage.py} ${./tests/cli-matrix.json}
            touch $out
          '';
          streamlocal-sentinel = pkgs.runCommand "wwn-ssh-streamlocal-sentinel" { } ''
            grep -q libssh2_channel_forward_listen_streamlocal ${./dependencies/libs/libssh2/patch-streamlocal.sh}
            touch $out
          '';
        });

      formatter = forAll (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
