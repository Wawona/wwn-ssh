# wwn-ssh

Wawona's App-Store-compliant SSH stack. Chooses the right backend per platform;
consumers merge `wwn-ssh.registryFragment` into the toolchain registry.

| Platform | Terminal `ssh` / `ssh-keygen` / `scp` | waypipe-over-SSH | fork/exec |
|---|---|---|---|
| iOS, iPadOS, tvOS, watchOS, visionOS | **libssh2 CLI** (`libwwn-ssh-cli.a`: `ssh_main` / `ssh_keygen_main` / `scp_main`) | patched **libssh2** streamlocal | no |
| Android / Wear OS | **OpenSSH** portable (`ssh`, `ssh-keygen`, `scp` in jniLibs) | `--ssh-bin` → OpenSSH | yes |
| macOS / Linux | **OpenSSH** (nixpkgs) | spawn `ssh` | yes |

**Hard rule:** Apple mobile never links or ships OpenSSH (`libssh-inprocess.a`). Legacy recipe under `dependencies/libs/openssh/ios.nix` is archaeology only.

## Version pins

See [`dependencies/libs/ssh-versions.nix`](dependencies/libs/ssh-versions.nix):

- libssh2 **1.11.1**
- OpenSSH portable **9.8p1** (Android)
- sshpass **1.10**
- macOS/Linux OpenSSH from nixpkgs (flake.lock)

## Registry keys

- `openssh` — Android/macOS/Linux OpenSSH; **null** on Apple mobile
- `libssh2` — streamlocal-patched library (waypipe + CLI link)
- `ssh-cli` — Apple in-process CLI archive
- `sshpass` — for platforms that spawn `ssh`

```nix
wwn-ssh.lib.backendFor "ios"
# => { sshBackend = "libssh2-cli"; waypipeSshTransport = "libssh2-inprocess"; forkExec = false; }

wwn-ssh.lib.backendFor "android"
# => { sshBackend = "openssh"; waypipeSshTransport = "exec-ssh"; forkExec = true; }
```

## CLI matrix / tests

Authoritative matrix: [`tests/cli-matrix.json`](tests/cli-matrix.json).

```sh
python3 tests/check-help-coverage.py tests/cli-matrix.json
nix build .#checks.aarch64-darwin.help-coverage
nix build .#libssh2-ios .#ssh-cli-ios .#ssh-cli-host .#openssh-android .#openssh-macos
# Headless matrix (required CI):
HOST=$(nix build .#ssh-cli-host --no-link --print-out-paths)
bash tests/run-matrix.sh ios "$HOST/bin"          # libssh2 CLI (Apple sources)
OSS=$(nix build .#openssh-macos --no-link --print-out-paths)
bash tests/run-matrix.sh macos "$OSS/bin"         # OpenSSH portable
# Android: aarch64 bins — build + OpenSSH_ string smoke (no host exec)
```

Key types: **ed25519**, **ecdsa**, **rsa**. GPG/OpenPGP: use `gpg --export-ssh-key` then `-i` (same OpenSSH key format); macOS may use gpg-agent SSH.

## Standalone build

```sh
nix build .#libssh2-ios
nix build .#ssh-cli-ios
nix build .#openssh-android   # OpenSSH portable for Android
nix build .#openssh-macos
nix build .#sshpass-macos
```

## License

MIT for Wawona packaging/patches. OpenSSH, libssh2, sshpass keep upstream licenses.
