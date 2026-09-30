# NNS — Native Nix Store

A KernelSU/SukiSU module and toolchain that gives Android a real, root-level
`/nix/store` on persistent f2fs — plus everything around it: a
user-namespace `nix-enter` launcher (no proot), a DNS/terminal preload
bridge, declarative runit services for boot-supervised daemons, a GKI kernel
build, and an Emacs integration. Primary target: Pixel 7 Pro (cheetah),
EvolutionX 16, SukiSU Ultra.

## Layout

- `module/` — KernelSU module: boot scripts, sepolicy, staged `/etc`,
  `nix-enter`. Start at [module/README.md](module/README.md).
- `nix/` — Nix derivations; `nix/nix-on-droid.nix` is the `nixOnDroid`-class
  module that replaces proot sessions with launcher sessions (imported
  host-side by rix101's `deploy .#cheetah`).
- `kernel/` — ACK/GKI `android14-6.1` build with SukiSU/SuSFS.
  See [kernel/README.md](kernel/README.md).
- `tests/` — unit and integration tests (dns, repack, userns, emacs) plus an
  Android VM harness; see [tests/android/README.md](tests/android/README.md).
- `integrations/emacs/` — `nns.el` and Android Emacs recovery scripts.
- `build.zig`, `module/src/*.zig` — launcher and preload-bridge sources;
  bridge documentation in [module/src/DNS.md](module/src/DNS.md).

## Outputs

From `outputs.nix`: `nns-module`, `nix-enter` (+ `-host`), `nns-dns`,
`emacs-integration`, `repack-boot`, `cheetah` (bundle), `kernel-cheetah`,
`test-userns`, `test-emacs`, `test-android`, `android-vm-test`, and matching
`checks`. `nix flake check` exercises dns, module, emacs, repack and kernel.

## Status

Launcher, store, bridge, kernel and the VM test: mature, documented in their
own READMEs. The session & services layer (deployed through rix101) is
**in progress**: green end-to-end on the device — deploy confirmed, kill tests
hand-run, and boot/unlock smoke-tested — but docs are partial. Scar-by-scar
rationale for the migration lives in the commit log (`jj log`), not all of it
in prose.

## Cheetah boot/unlock regression

Run `python3 tests/device-boot-smoke.py prepare` from this checkout to reboot
cheetah and check pre-unlock supervision. **Do not unlock the phone** until it
prints the pre-unlock result. After unlocking, run
`python3 tests/device-boot-smoke.py verify` to check SSH and launch Android
Emacs to verify its graphical server. Set `ANDROID_SERIAL` for another ADB
serial; SSH currently targets `cheetah.lan:8022`. This test requires a real
phone and is not part of `nix flake check`.

## Android Emacs recovery

After installing or clearing native Android Emacs, unlock and open it once so
Android creates its app-private files, then close it. With ADB connected,
NoD's SSH/socket services running, the desktop Emacs configuration, and
Maple Mono NF CN Regular installed on the host, run:

```sh
./integrations/emacs/provision-android-emacs.sh
```

The command restores the GUI configuration, font, and straight.el repositories
(if absent), preserves an existing app SSH key or creates one after a wipe,
updates NoD's restricted authorized key, and pins its current SSH host key.
It refuses a changed pinned host key rather than silently trusting it. It
refreshes the existing `emacs-socket` service, starts Android Emacs, and waits
for its server. Set `ANDROID_SERIAL` to select a different ADB device.
Do not run it while Android Emacs is open.

From NoD zsh or Nushell, `emacs-gui FILE` opens a NoD path in that GUI via
TRAMP, for example `emacs-gui ~/.zshrc`. The GUI must be running; the NoD
shell does not start a second Emacs server.

## Docs

- [module/README.md](module/README.md) — mechanism, device constraints,
  sessions & supervised services (in progress)
- [kernel/README.md](kernel/README.md) — build, patches, config rationale
- [module/src/DNS.md](module/src/DNS.md) — DNS bridge and ioctl shim
- [tests/android/README.md](tests/android/README.md) — VM security test
