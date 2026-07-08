{
  lib,
  pkgs,
  ...
}:

# Linux uses stock OpenSSH from nixpkgs.
pkgs.openssh
