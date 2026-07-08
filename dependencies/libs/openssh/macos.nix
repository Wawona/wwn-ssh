{
  lib,
  pkgs,
  ...
}:

# macOS SSH backend: regular OpenSSH from nixpkgs (ssh, ssh-keygen, ssh-agent,
# ssh-add, scp, sftp). macOS has no App Store style fork/exec restriction, so
# the stock client is both compliant and fully featured (ed25519, ed25519-sk
# via security keys, ssh-agent, ~/.ssh/config). Bundle-friendly: the Wawona
# macOS app is itself a nix closure, so store references are fine.
pkgs.openssh
