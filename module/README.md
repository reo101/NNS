# NNS — Native Nix Store

A KernelSU/SukiSU module that provides a **real, root-level `/nix`** on
Android. Not proot, not a symlink farm — an actual `/nix/store` backed by
persistent f2fs, visible to anything launched through the `nix-enter` helper.

## Status

Working on: Pixel 7 Pro (cheetah), EvolutionX 16 (Android 16), kernel 6.1.134
(probed from the running device; the NNS-built image has its own story in
`kernel/README.md`), SukiSU Ultra (ksud 4.2.0-1-g904c60d1, script-only module
handling).

Current work: proot-free Nix-on-Droid sessions and boot-supervised services —
see "Sessions and supervised services" below. That layer is **in progress**:
behavior is verified end-to-end on the phone, documentation and regression
tests lag behind it.

```
su -c '/data/adb/modules/nix/bin/nix-enter <command>'
```

Everything the command spawns (fork/exec) inherits a root view with `/nix`.
Nothing outside the session is touched; the host system is never modified at
boot.

## Why this is weird (device constraints, all verified empirically)

- `/` is system-as-root: RO ext4 on dm-0 with **verity enforcing**. Unwritable,
  period. `/system` is not even a mount here — it's a plain dir on the dm-0
  root fs (EvolutionX layout), so module `root/`-style overlays can't apply
  and SukiSU on this build never mounts modules anyway (script-only).
- **f2fs cannot be an overlayfs upper** on this kernel (no `overlay` feature
  flag on `/data` or `/metadata`). Loop-mounted ext4 uppers die on *maximum fs
  stacking depth* (loop over f2fs over dm).
- overlayfs with `lowerdir=/` mounted **on** `/` does not cover root-level
  path lookups — `mkdir /nix` goes straight to dm-0 and gets EROFS.
- **Global (boot-time) root pivot is a dead end**: `pivot_root` in init's
  mount namespace re-roots the namespace, but init's `fs->root` stays on the
  old tree, which the dance guts by moving submounts — every service init
  spawns afterwards crash-loops (observed: all updatable services "exited 4
  times before boot completed"). A `pivot_root` can only help processes
  started *by the pivot caller*.
- On this kernel `pivot_root` does **not** carry submounts into the new root,
  and shared propagation blocks `mount --move`; per-mount make-private is not
  enough — the whole tree goes `--make-rprivate` first. `/data` cannot be
  moved onto a target under itself (VFS cycle check), so the new root anchors
  on `/tmp` (standalone tmpfs on this ROM) and /data's move happens mid-dance.
- Stacked same-path mounts (`/linkerconfig` base tmpfs + its `/default` bind
  on top) must be moved **once**; a second move of the top layer inverts the
  stack and hides `ld.config.txt` (the bash prototype hit this via `sort -u`
  by accident).
- `/proc` files report `st_size=0`; anything reading them through a
  size-aware API gets nothing. Read the fd until EOF.
- SukiSU's KPM/eBPF kernel hooks are unavailable on this kernel build
  (`ksud kpm` → ENOTTY), so no kernel-level trickery without a reflash.

## Mechanism (`bin/nix-enter`, zig 0.16, no libc, static aarch64)

1. `unshare(CLONE_NEWNS)`, `mount --make-rprivate /`.
2. tmpfs new root at `/tmp/nixroot.<pid>`; `mount --move` every top-level
   submount into it, one move per unique mountpoint (stacked mounts travel
   with their parent).
3. Symlink the dm-0 leftovers through `/old` (`/system -> old/system`, …).
4. `pivot_root`; fresh tmpfs on `/tmp`; `mount --bind /data/nix /nix`.
5. `exec` the requested command.

The store lives at `/data/nix/{store,var,tmp}` (f2fs, persistent, survives
reboots; whatever you install stays installed).

## For app developers (Android Emacs)

A running app's path resolution is rooted at its own `fs->root`; no mount
namespace trick can change that after the fact. Apps can launch subprocesses
through `nix-enter` without moving the app itself into `/nix`. Native Android
Emacs uses `nns.el` for those subprocesses and remains the GUI server. The
unlock-gated `emacs-socket` service prepares `/data/nix/var/emacs-server/` for
both the GUI app and NoD; `emacsclient` in NoD connects to its Unix socket.
The GUI accesses NoD-private files through TRAMP over SSH to
`127.0.0.1:8022`, using a pinned host key and a restricted app key. This path
stays on the phone; it does not depend on LAN access. For host-side recovery
after app-data loss, see [Android Emacs recovery](../README.md#android-emacs-recovery).

## Sessions and supervised services (in progress)

Proot is gone; three layers sit above the launcher:

- **Nix-on-Droid module** (`nix/nix-on-droid.nix`, exported as
  `nixOnDroidModules.nns`, wired host-side by rix101's `deploy .#cheetah`):
  replaces NoD proot sessions with `nix-enter` user-namespace sessions and a
  root daemon (`NIX_REMOTE=daemon`). `build.linkProotStatic = false` —
  activation writes the app prefix directly instead of a proot tree. There is
  no `/android` alias: the old `dnshackresolver` needed proot's `-b /:/android`
  mapping, but NNS's Bionic DNS helper requests `/system/bin/linker64` from
  the real Android root. Only the NNS bridge should be preloaded in sessions.
- **Staged `/etc`**: `stage-etc.sh` materializes `/data/nix/var/daemon-etc`,
  the bind-pinned `/etc` seen by daemon and runsvdir sessions. It re-stages
  in place (directory inodes must not move), resolving passwd/group from
  credential-encrypted storage when available, else a pre-unlock seed — so
  sessions spawned before first unlock run the seed shell until a post-unlock
  re-stage. Extra `name:uid:gid` lines in `/data/nix/etc/nss-trusted` become
  passwd/group entries plus `nix-trusted` membership (seeded for sshd privsep).
- **`nns.services`**: modular services backed by runit. Declare
  `nns.services.services.<name>` with portable `process.argv` and
  `process.environment`, or import a nixpkgs `_class = "service"` module.
  `nns.enable`, `nns.startAt` (`boot` or `unlock`), and `nns.after` are
  backend-only options; portable modules can guard them with `options ? nns`.
  Shell `script`/`env` definitions are no longer supported. For example:

  ```nix
  nns.services.services.example = {
    process.argv = [ "/system/bin/sleep" "3600" ];
    process.environment.EXAMPLE = "value with spaces";
    nns.startAt = "unlock";
  };
  ```

  The dedicated `services.sshd` still accepts
  `enable/port/listenAddress/extraConfig` (config rendered from nix). Service
  dirs and runit tools materialize to `/data/nix/var/nns/{services,bin}`;
  `service.sh` starts `runsvdir` behind a pidfile+cmdline gate (recycled pids
  distrusted); `nns.startAt = "unlock"` waits on the `nns-unlock-ready` sentinel
  via `nns-wait`. Activation deliberately never touches the live runsv (root
  control sockets vs app-uid activation) — services apply at boot or via a
  manual `service.sh` run. Nested services, `configData`, reload and notification
  protocols are rejected rather than silently ignored. Services must remain
  in the foreground; NNS does not interpret `systemd.*` options.

sshd is the first service: state in credential-encrypted `/data/nix/var/sshd`
(config, host keys, pid, logs, authorized_keys; mode 700),
`SetEnv NIX_REMOTE=daemon` for every session, `StrictModes no` with `/data/nix`
pinned `0:0` at boot (Android's `771 system:system` ancestry; Termux
precedent), and patched `sshd`/`sshd-auth` copies whose `/var/empty` became
`/data/ve` (uncreatable on this ROM), bind-mounted over the store originals
inside the session namespace — guarded by a fatal assertion, after an earlier
silent `dd` failure shipped unpatched helpers that only said "Missing
privilege separation directory".

Status: end-to-end green on device (deploy confirmed, kill + boot tests
hand-run). Shizuku's `app_process`/Binder path is now verified on-device; the
Nix-on-Droid module installs NNS-owned `rish`/`su`/`sudo` wrappers so the stale
upstream `service list` preflight is bypassed. Still missing: doc depth and
broader boot-layer regression coverage. Host-initiated deployments use
`cheetah.lan:8022` from rix101's `meta.nix`; this is separate from Emacs's
on-phone loopback connection. Sepolicy rationale lives in the commit log
(`jj log`), not next to `sepolicy.rule`;
ksud's `allowxperm` rules are dropped by its sepolicy parser, so the
terminal-ioctl workaround rides in `libnns-dns.so` — see `src/DNS.md`.

## Seeding the store

Store paths are content-addressed and positional — build a closure on a PC
and tar it into the store:

```sh
# PC (NixOS), cross paths match cache.nixos.org aarch64 builds:
nix build nixpkgs#pkgsCross.aarch64-multiplatform.<pkg> -o out/<pkg>
nix build --impure --expr 'with import <nixpkgs> { system = "aarch64-linux"; }; buildEnv { name = "phone-profile"; paths = [ ... ]; }'
# closure union -> tar (NO --sparse: busybox tar dies on sparse members;
# no hardlink-order games once gnutar is in the store - extract with it)
tar -cf bootstrap.tar --numeric-owner -T paths.txt
adb push bootstrap.tar /data/local/tmp/
# phone, inside a session (busybox for the first seed, store gnutar after):
su -c 'nix-enter <tar> -xf /data/local/tmp/bootstrap.tar -C /'
```

Then wire the profile (versioned, so a broken bump is rolled back by
repointing `system-profile`):

```sh
ln -sfn <env-store-path> /nix/var/nix/profiles/system-profile-1-link
ln -sfn system-profile-1-link /nix/var/nix/profiles/system-profile
```

`/data/nix/etc/profile` sources on session start (`nix-enter sh -c '. /data/nix/etc/profile; …'`);
nix.conf at `/data/nix/etc/nix/nix.conf` (root builds, no nixbld, sandbox off).

Android init recursively restores labels under `/data` before NNS boot scripts run.
After populating the store, seed its `security.sehash` cache once:

```sh
adb shell su -c 'restorecon -R /data/nix/store'
```

The first pass took 973 seconds on cheetah. A repeated pass should report
`Skipping restorecon on directory(/data/nix/store)`; on the next boot,
init's `/data` restorecon fell from 448.6 seconds to 0.668 seconds.
The store's files retain their expected `system_data_file` label.

## Deploy

```sh
nix build .#nns-module           # -> result/nns-module.zip (launcher + bridge + scripts)
nix build .#nns-sepolicy         # -> rendered sepolicy.rule from module/sepolicy.rule.in
nix build .#nns-sepolicy-candidates # -> result/sepolicy-candidates.txt (review only)
nix build .#nns-rom-sepolicy     # -> compiled ROM baseline (x86_64-linux, 3.2 GB OTA download)
# or hack the launcher directly:
zig build-exe src/nix-enter.zig -target aarch64-linux-musl -O ReleaseSmall -femit-bin=bin/nix-enter
# push module/* to /data/adb/modules/nix/ and re-sync the zip
adb reboot     # only needed once, for post-fs-data store prep
```

The policy template expands the app-domain transitions and pipe rules into
single-source statements that ksud accepts. The candidate report cites public
Evolution X policy revisions preceding the 2026-08-08 OTA build, but is **not**
a compiled policy: M4 macros, other build inputs and proprietary vendor rules
are absent. Candidate statements are never added to the installed policy
without review. The separate ROM baseline derivation downloads the official
2026-08-08 Pixel 7 Pro OTA (SHA-256 pinned), extracts only its vendor partition,
and pins `etc/selinux/precompiled_sepolicy` as a flat fixed-output derivation
against the installed ROM's pre-module policy SHA-256. It does not feed the
module policy or package a captured device artifact. The extraction needs no
network, but a cold build must fetch the 3.2 GB OTA unless the input or final
output is available from a store or substituter. Query the result with `sesearch -A -s
untrusted_app_27 ./result` (SETools); include target, class and permission
filters when reviewing individual operations. The live policy includes KernelSU
patches and is not the ROM baseline.

Host-side full-system deploy (NoD generation + activation): from
`~/.config/rix101`, `deploy .#cheetah --skip-checks` after
`nix flake lock --update-input nns` (NNS is a `path:`-pinned input).

Logs: `/data/local/tmp/nix-{enter,post-fs-data,daemon,service}.log`.
Disable: `touch /data/adb/modules/nix/disable` (KernelSU's native toggle;
the old `/data/nix/.disable` was never wired to anything).
