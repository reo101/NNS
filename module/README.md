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

## For app developers (the emacs problem)

A running app's path resolution is rooted at its own `fs->root`; no mount
namespace trick can change that after the fact. Apps that spawn subprocesses
can opt in by running them through `su -c nix-enter …` (grant the app in
SukiSU). Apps that only exec in-process (android emacs) need either the
shared-uid trick (exec the helper from a paired root-capable app) or a root
session daemon the app talks to over a socket — v2 territory.

## Sessions and supervised services (in progress)

Proot is gone; three layers sit above the launcher:

- **Nix-on-Droid module** (`nix/nix-on-droid.nix`, exported as
  `nixOnDroidModules.nns`, wired host-side by rix101's `deploy .#cheetah`):
  replaces NoD proot sessions with `nix-enter` user-namespace sessions and a
  root daemon (`NIX_REMOTE=daemon`). `build.linkProotStatic = false` —
  activation writes the app prefix directly instead of a proot tree.
- **Staged `/etc`**: `stage-etc.sh` materializes `/data/nix/var/daemon-etc`,
  the bind-pinned `/etc` seen by daemon and runsvdir sessions. It re-stages
  in place (directory inodes must not move), resolving passwd/group from
  credential-encrypted storage when available, else a pre-unlock seed — so
  sessions spawned before first unlock run the seed shell until a post-unlock
  re-stage. Extra `name:uid:gid` lines in `/data/nix/etc/nss-trusted` become
  passwd/group entries plus `nix-trusted` membership (seeded for sshd privsep).
- **`nns.services`**: declarative runit services — `services.<name>` with
  `enable/startAt/after/script/env`, plus `services.sshd` with
  `enable/port/listenAddress/extraConfig` (config rendered from nix). Service
  dirs and runit tools materialize to `/data/nix/var/nns/{services,bin}`;
  `service.sh` starts `runsvdir` behind a pidfile+cmdline gate (recycled pids
  distrusted); `startAt = "unlock"` waits on the `nns-unlock-ready` sentinel
  via `nns-wait`. Activation deliberately never touches the live runsv (root
  control sockets vs app-uid activation) — services apply at boot or via a
  manual `service.sh` run.

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
hand-run). Still missing: doc depth, boot-layer regression tests, a durable
transport story (LAN / adb-forward / WireGuard flap in `meta.nix`), and
Shizuku running for rish/`su` (they now fail loudly without it). Sepolicy
rationale lives in the commit log (`jj log`), not next to `sepolicy.rule`;
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

Then wire the profile:

```sh
ln -sfn <env-store-path> /nix/var/nix/profiles/default-1
ln -sfn default-1 /nix/var/nix/profiles/default
ln -sfn default /nix/var/nix/profiles/profile
```

`/data/nix/etc/profile` sources on session start (`nix-enter sh -c '. /data/nix/etc/profile; …'`);
nix.conf at `/data/nix/etc/nix/nix.conf` (root builds, no nixbld, sandbox off).

## Deploy

```sh
nix build .#nns-module           # -> result/nns-module.zip (launcher + bridge + scripts)
# or hack the launcher directly:
zig build-exe src/nix-enter.zig -target aarch64-linux-musl -O ReleaseSmall -femit-bin=bin/nix-enter
# push module/* to /data/adb/modules/nix/ and re-sync the zip
adb reboot     # only needed once, for post-fs-data store prep
```

Host-side full-system deploy (NoD generation + activation): from
`~/.config/rix101`, `deploy .#cheetah --skip-checks` after
`nix flake lock --update-input nns` (NNS is a `path:`-pinned input).

Logs: `/data/local/tmp/nix-{enter,post-fs-data,daemon,service}.log`.
Disable: `touch /data/adb/modules/nix/disable` (KernelSU's native toggle;
the old `/data/nix/.disable` was never wired to anything).
