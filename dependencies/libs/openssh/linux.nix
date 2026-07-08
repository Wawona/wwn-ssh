{
  lib,
  pkgs,
  ...
}:

# Linux uses stock OpenSSH from nixpkgs. getBin: openssh is multi-output and
# consumers scan buildInputs for bin/ssh, so hand out the binary output.
lib.getBin pkgs.openssh
