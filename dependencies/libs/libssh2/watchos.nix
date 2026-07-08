{ lib, pkgs, buildPackages, common, buildModule, simulator ? false, iosToolchain ? null, toolchainSrc ? null, ... }:

# Explicit watchOS module forwarding to the platform-adjusted iOS recipe.
let
  iosModule = import ./ios.nix;
  forwarded = {
    inherit lib pkgs buildPackages common buildModule simulator iosToolchain toolchainSrc;
  };
in
iosModule (builtins.intersectAttrs (builtins.functionArgs iosModule) forwarded)
