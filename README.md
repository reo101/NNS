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

`lib.nnsSystem` evaluates the standalone `nns` module class.
`nnsModules.default` exports its base module.

From `outputs.nix`: `nns-module`, `nix-enter` (+ `-host`), `nns-dns`,
`emacs-integration`, `repack-boot`, `cheetah` (bundle), `kernel-cheetah`,
`test-userns`, `test-emacs`, `test-android`, `android-vm-test`, and matching
`checks`. `nix flake check` exercises dns, module, emacs, repack and kernel.

## Native builds

`build.zig` compiles the standalone Zig and C artifacts and runs their tests.
`nix build .#nns-native` builds the complete ARM64 set. Existing per-artifact
packages remain separate. Nix supplies pinned dependencies, the Android NDK,
and Linux headers; compilation does not download packages.

See [native build instructions](docs/native-build.md) for named steps,
host tests, and direct Zig builds. APK, ROM, and kernel assembly remain in
Nix and their platform build systems.

## Status

NNS 3.2.0 and its standalone system generation run on cheetah. Root SSH and
the Nix daemon start before Android unlock. NoD and native Android Emacs
retain their separate UIDs and homes after unlock.

Historical generation rollback, failed-activation rollback, confirmation
timeout, and ordered NNS/NoD rollback passed on the phone. The tests restored
the working deployment and its shared configuration.

See [NNS systems and package profiles](docs/nns-systems.md) for ownership,
NoD integration, Emacs profile selection, and retention. Build isolation
remains deferred, see [the research notes](docs/build-isolation.md).

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
NNS SSH and Emacs socket services running, the desktop Emacs configuration, and
Maple Mono NF CN Regular installed on the host, run:

```sh
./integrations/emacs/provision-android-emacs.sh
```

The command restores the GUI configuration, font, and straight.el repositories
(if absent), preserves an existing app SSH key or creates one after a wipe,
updates NoD's restricted authorized key, and pins the NNS SSH host key.
It refuses a changed pinned host key rather than silently trusting it. It
refreshes the existing `emacs-socket` service, starts Android Emacs, and waits
for its server. Set `ANDROID_SERIAL` to select a different ADB device.
Do not run it while Android Emacs is open.

From NoD zsh or Nushell, `emacs-gui FILE` opens a NoD path in that GUI via
TRAMP, for example `emacs-gui ~/.zshrc`. The GUI must be running; the NoD
shell does not start a second Emacs server.

## Docs

- [docs/nns-systems.md](docs/nns-systems.md): system generations, consumers, and deploy-rs
- [docs/build-isolation.md](docs/build-isolation.md): current build risks and deferred designs
- [benchmarks/storage-backends](benchmarks/storage-backends/README.md): measured Btrfs backing cost and durability, and why directory mode remains

- [module/README.md](module/README.md) — mechanism, device constraints,
  sessions & supervised services (in progress)
- [kernel/README.md](kernel/README.md) — build, patches, config rationale
- [module/src/DNS.md](module/src/DNS.md) — DNS bridge and ioctl shim
- [tests/android/README.md](tests/android/README.md) — VM security test
