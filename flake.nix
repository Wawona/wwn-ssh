{
  description = "wwn-ssh: Wawona's App-Store-compliant SSH stack. Chooses the right backend per platform: in-process OpenSSH + libssh2 on Apple mobile (iOS/iPadOS/tvOS/watchOS/visionOS, no fork/exec), Dropbear (dbclient as ssh + dropbearkey) on Android, and regular OpenSSH on macOS/Linux. Plus sshpass for non-interactive password auth.";

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

      opensshDir = ./dependencies/libs/openssh;
      libssh2Dir = ./dependencies/libs/libssh2;
      sshpassDir = ./dependencies/libs/sshpass;
    in
    {
      registryFragment = {
        # Registry key stays "openssh" (the terminal `ssh` / `ssh-keygen`
        # command surface), but wwn-ssh picks the compliant backend:
        #   Apple mobile -> OpenSSH 9.8p1 built as libssh-inprocess.a
        #                   (ssh_main/ssh_keygen_main/scp_main, no fork/exec)
        #   Android      -> Dropbear (dbclient installed as ssh, dropbearkey
        #                   as ssh-keygen; fork/exec of jniLibs is allowed)
        #   macOS/Linux  -> regular OpenSSH from nixpkgs
        openssh = withPlatformVariants {
          android = opensshDir + "/android.nix";
          wearos = opensshDir + "/wearos.nix";
          ios = opensshDir + "/ios.nix";
          ipados = opensshDir + "/ios.nix";
          tvos = opensshDir + "/tvos.nix";
          visionos = opensshDir + "/visionos.nix";
          watchos = opensshDir + "/watchos.nix";
          macos = opensshDir + "/macos.nix";
          linux = opensshDir + "/linux.nix";
        };
        # libssh2 (+ streamlocal-forward@openssh.com patch): the in-process
        # transport waypipe uses for `waypipe ssh` on Apple mobile.
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
        # wwn-ssh owns the backend decision. Consumers (Wawona Settings,
        # machine configuration, waypipe wiring) can consult this instead of
        # hard-coding platform conditionals.
        #   sshBackend:     what implements the `ssh` command line
        #   waypipeSshTransport: how `waypipe ssh` tunnels
        backends = {
          ios = { sshBackend = "openssh-inprocess"; waypipeSshTransport = "libssh2-inprocess"; forkExec = false; };
          ipados = { sshBackend = "openssh-inprocess"; waypipeSshTransport = "libssh2-inprocess"; forkExec = false; };
          tvos = { sshBackend = "openssh-inprocess"; waypipeSshTransport = "libssh2-inprocess"; forkExec = false; };
          watchos = { sshBackend = "openssh-inprocess"; waypipeSshTransport = "libssh2-inprocess"; forkExec = false; };
          visionos = { sshBackend = "openssh-inprocess"; waypipeSshTransport = "libssh2-inprocess"; forkExec = false; };
          android = { sshBackend = "dropbear"; waypipeSshTransport = "exec-ssh"; forkExec = true; };
          wearos = { sshBackend = "dropbear"; waypipeSshTransport = "exec-ssh"; forkExec = true; };
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
        } // (if isDarwin then {
          openssh-ios = tc.buildForIOS "openssh" { };
          libssh2-ios = tc.buildForIOS "libssh2" { };
          sshpass-ios = tc.buildForIOS "sshpass" { };
          openssh-macos = tc.buildForMacOS "openssh" { };
          sshpass-macos = tc.buildForMacOS "sshpass" { };
        } else {
          openssh-linux = tc.buildForLinux "openssh" { };
          sshpass-linux = tc.buildForLinux "sshpass" { };
        }));

      formatter = forAll (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
