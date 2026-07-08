# wwn-ssh

Wawona's App-Store-compliant SSH stack, split out of
[wwn-toolchain](https://github.com/Wawona/wwn-toolchain) so the SSH patches for
every target live in one place. `wwn-ssh` is responsible for choosing the right
backend per platform; consumers keep using the `openssh` / `libssh2` /
`sshpass` registry keys unchanged.

| Platform | `ssh` / `ssh-keygen` command | `waypipe ssh` transport | fork/exec |
|---|---|---|---|
| iOS, iPadOS, tvOS, watchOS, visionOS | OpenSSH 9.8p1 built as `libssh-inprocess.a` (`ssh_main`, `ssh_keygen_main`, `scp_main`; dispatched in-process by `wawona-dispatch.c`) | patched libssh2 (in-process, `streamlocal-forward@openssh.com`) | no (App Store compliant) |
| Android / Wear OS | Dropbear (`dbclient` installed as `ssh`, `dropbearkey` as `ssh-keygen`, plus `scp`, `dropbearconvert`; exec'd from jniLibs) | external `ssh` via waypipe `--ssh-bin` (Play compliant) | yes |
| macOS | regular OpenSSH (nixpkgs) bundled + system fallback | external `ssh` spawn | yes |
| Linux | regular OpenSSH (nixpkgs) | external `ssh` spawn | yes |

Key generation works everywhere: `ssh-keygen -t ed25519 -f <file>` (on Android
this is Dropbear's `dropbearkey`, which shares the `-t/-f/-y` CLI;
`dropbearconvert` translates OpenSSH ⇄ Dropbear private key formats).

## Patches carried here

- `dependencies/libs/openssh/ios.nix` — OpenSSH iOS port: env-var password auth
  (`SSH_ASKPASS_PASSWORD` / `SSHPASS`), synthetic `getpwuid` fallbacks, no-TTY
  handling, `libssh-inprocess.a` with `ssh_main` / `ssh_keygen_main`.
- `dependencies/libs/openssh/android.nix` + `patch-dbclient-streamlocal.sh` —
  Dropbear with `-R /remote.sock:/local.sock` Unix-socket forwarding
  (`streamlocal-forward@openssh.com`, required by waypipe) and `SSHPASS` support.
- `dependencies/libs/libssh2/*` + `patch-streamlocal.sh` — libssh2 1.11.1 with
  `libssh2_channel_forward_listen_streamlocal()` for waypipe's in-process
  Apple-mobile transport.
- `dependencies/libs/sshpass/*` — sshpass 1.10 for all targets.

## Use

```nix
inputs.wwn-ssh.url = "github:Wawona/wwn-ssh";
registry = wwn-toolchain.lib.baseRegistry // wwn-ssh.registryFragment;
```

Backend metadata for Settings / machine configuration:

```nix
wwn-ssh.lib.backendFor "ios"
# => { sshBackend = "openssh-inprocess"; waypipeSshTransport = "libssh2-inprocess"; forkExec = false; }
```

## Standalone build

```sh
nix build .#openssh-ios       # libssh-inprocess.a (Apple mobile)
nix build .#libssh2-ios       # static libssh2 + streamlocal patch
nix build .#openssh-android   # Dropbear: ssh, ssh-keygen, scp, dropbearconvert
nix build .#openssh-macos     # regular OpenSSH
nix build .#sshpass-macos
```

## License

MIT for the Wawona Nix packaging / patches (see `LICENSE`). OpenSSH (BSD),
Dropbear (MIT), libssh2 (BSD-3), and sshpass (GPL-2.0-or-later) keep their own
licenses; sources are fetched from upstream at build time.
