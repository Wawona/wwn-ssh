# Central version pins for wwn-ssh. Every recipe imports this so hashes stay
# reproducible and CI can assert versions match.
{
  libssh2 = {
    version = "1.11.1";
    rev = "libssh2-1.11.1";
    sha256 = "sha256-yz97oqqN+NJTDL/HPJe3niFynbR8QXHuuiKr+uuKJtw=";
  };

  # OpenSSH portable — Android product path + Apple archaeology only.
  opensshPortable = {
    version = "9.8p1";
    url = "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.8p1.tar.gz";
    # Cloudflare CDN mirror (same tarball) used if primary flakes:
    urlAlt = "https://cloudflare.cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.8p1.tar.gz";
    sha256 = "sha256-3YvQAqN5tdSZ37BQ3R+pr4Ap6ARh9LtsUjxJlz9aOfM=";
  };

  sshpass = {
    version = "1.10";
    url = "https://sourceforge.net/projects/sshpass/files/sshpass/1.10/sshpass-1.10.tar.gz";
    sha256 = "sha256-rREGwgPLtWGFyjutjGzK/KO0BkaWGU2oefgcjXvf7to=";
  };

  # Documented nixpkgs OpenSSH line for macOS/Linux (floats with flake.lock).
  # CI may assert: nix eval nixpkgs#openssh.version
  opensshNixpkgsNote = "nixpkgs openssh (bundled via macos.nix / linux.nix)";
}
