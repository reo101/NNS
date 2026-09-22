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
- `integrations/emacs/` — `nns.el`.
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
**in progress**: green end-to-end on the device — deploy confirmed, kill and
boot tests hand-run — but docs are partial and the boot layer has no
regression tests yet. Scar-by-scar rationale for the migration lives in the
commit log (`jj log`), not all of it in prose.

## Docs

- [module/README.md](module/README.md) — mechanism, device constraints,
  sessions & supervised services (in progress)
- [kernel/README.md](kernel/README.md) — build, patches, config rationale
- [module/src/DNS.md](module/src/DNS.md) — DNS bridge and ioctl shim
- [tests/android/README.md](tests/android/README.md) — VM security test
