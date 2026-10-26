# NNS — Native Nix Store

A KernelSU/SukiSU module that provides a **real, root-level `/nix`** on
Android. Not proot, not a symlink farm — an actual `/nix/store` backed by
persistent storage, visible to anything launched through the `nix-enter` helper.
The default backing is a directory on Android userdata. Btrfs images are opt-in.

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
The launcher does not change the global root.

## Optional Btrfs backing

The module can mount an existing, single-device Btrfs image at `/data/nix`.
It does not create, format, repair, resize or migrate filesystems. The kernel
must support Btrfs and loop devices. SELinux must permit the mount and access
to the prepared file labels. No policy relaxation is added for this backend.

This backend is not enabled and is not used. Directory mode remains the
deployed mode. Measured phone results, including a durability gap where `fsync`
does not reach the backing device, are in
[Btrfs backing evaluation](../benchmarks/storage-backends/README.md). Read that
document before selecting this backend.

Persistent configuration lives at `/data/nns-storage/backing.conf`, outside the
module and the mounted filesystem. Without this file, directory mode remains
unchanged. The configuration contains exactly three newline-terminated fields:

```ini
image=nix.btrfs
uuid=11111111-2222-3333-4444-555555555555
subvolume_id=256
```

Replace the example UUID and subvolume ID with the prepared volume's values.
`image` is a basename inside `/data/nns-storage`, not an arbitrary path.
Subvolume ID `5` selects the top-level tree. Other valid IDs start at `256`.
Blank lines, comments, unknown fields and duplicate fields are refused.
The file is parsed as data, never sourced as shell code.
If the directory uses fscrypt (per-directory file encryption), its key must be
available before configuration lookup. A locked directory is an error, not
an absent configuration or a request for directory fallback.

Use root:root ownership, mode `0700` for `/data/nns-storage`, and mode `0600`
for the configuration and image. Image and configuration files must be regular
files with one hard link. Symlinks are refused. The selected subvolume root and
existing `/data/nix` mountpoint must be root-owned and not group- or world-writable.
The image must be available before first unlock. Its Android encryption policy
and loop-device behavior require device-specific testing.

The static Zig `bin/nns-storage` helper uses Linux syscalls without libc.
It uses these operations:

| Command | Behavior |
| --- | --- |
| `nns-storage --mode` | Read configuration and report `directory` or `btrfs` |
| `nns-storage --check` | Require the configured backing without mounting or repairing it |
| `nns-storage` | Mount configured backing, or retain an identical existing mount |

For Btrfs, the helper requires init's mount namespace. It checks the filesystem
UUID, subvolume ID, single-device layout and actual loop backing inode.
A copied image with the same UUID does not authorize reuse of another image's
existing mount. Stacked mounts, read-only storage and conflicting flags are
refused. Mounts use `nosuid,nodev,compress=zstd:3,nodiscard`, with execution
permitted. A failed mount can still trigger normal kernel journal replay.
`--check` does not attach loop devices or modify filesystem settings.

In module-owned mode, Btrfs preparation moves to `service.sh` before any Nix
runtime writes. The early `post-fs-data.sh` hook only reads the configuration.
Installation and direct runtime preparation require an already mounted volume.
Install the module before selecting an unmounted image in the configuration.

For a semi-manual migration:

1. Prepare an image with features supported by the target kernel. Reserve both
   inner and outer free space. Keep the image outside `/data/nix`.
2. Stop the daemon, builds, services, activation and all Nix sessions. Use an
   Android control shell and tools outside the migrating tree.
3. Copy the complete tree into the prepared subvolume. Preserve hardlinks,
   symlinks, numeric ownership, permissions, ACLs and applicable xattrs. Keep
   the store, database, profiles, roots and mutable state together.
4. Make sure that the copied data and Android file labels are correct. Retain
   the original tree separately and leave an empty root-owned `/data/nix`.
5. Publish the configuration while consumers remain stopped, then reboot.
   Make sure that the backing, profiles and services work before deleting backups.

Removing the configuration selects directory mode. It does not unmount Btrfs
or copy data back. Stop consumers and perform a cold reverse migration first.
Returning to the original tree discards changes made after the cutover.

Build the Cheetah archive with `nix build .#nns-module-cheetah`.
Run `nix build .#checks.x86_64-linux.nns-storage` for the Linux 6.1 VM test.
The VM exercises Btrfs on F2FS, mount retention, refusal cases and loop cleanup.
It does not establish Android SELinux, encrypted-backing or root-manager boot
compatibility. No phone migration is performed by the build or test.

Before the Zig port, an isolated Cheetah probe passed on the running 6.1.162 kernel. The 256 MiB
Btrfs image mounted on F2FS with Zstd compression. Writes and file labels
survived unmount and remount. Wrong UUIDs, wrong subvolumes and private mount
namespaces were refused. Unmount removed the loop attachment and propagated
to the existing NoD and Emacs namespaces. Both apps executed a static probe
from Btrfs with their original UIDs in enforcing `nns_app` domains.

This result does not approve production deployment. The default
`system_data_file` label blocked kernel-worker reads of the image. Only the
disposable image used the existing `shell_data_file` test label. Do not use
that label as the production solution. The mount controller ran in the
pre-existing permissive `ksu` domain and logged denied Btrfs inspection ioctls.
An enforcing mount controller needs explicit permissions for these operations.
The backing file had no fscrypt policy, so encrypted-file compatibility and
availability before first unlock remain untested. No boot test or live Nix
migration occurred. The probe files and mounts were removed. The installed
module, live Nix directory identities and SELinux policy remained unchanged.

The disposable fixture is built by
[`tests/android/storage-probe.nix`](../tests/android/storage-probe.nix).
Its execution probe reports `namespace=0` when Android denies namespace
metadata. This does not replace the separate mount-propagation checks.

The Zig port passes the Linux Btrfs-on-F2FS regression and a separate
locked-key configuration test. ARM64 and x86-64 builds pass.
These checks do not establish Android boot or phone compatibility for the port.

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

## Mechanism (`bin/nix-enter`, Zig 0.17, no libc, static aarch64)

1. `unshare(CLONE_NEWNS)`, `mount --make-rprivate /`.
2. tmpfs new root at `/tmp/nixroot.<pid>`; `mount --move` every top-level
   submount into it, one move per unique mountpoint (stacked mounts travel
   with their parent).
3. Symlink the dm-0 leftovers through `/old` (`/system -> old/system`, …).
4. `pivot_root`; fresh tmpfs on `/tmp`; `mount --bind /data/nix /nix`.
5. `exec` the requested command.

The store lives at `/data/nix/{store,var,tmp}`. Its persistent backing is the
userdata directory or the selected Btrfs image.

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

## Sessions and supervised services

The standalone NNS system owns the daemon, administrative SSH, accounts,
and root services. The boot module activates its selected generation.
Root activation stages `/data/nix/var/daemon-etc` without replacing directory
inodes, so existing service namespaces retain access to updated files.
Android's own `/etc` remains unchanged.

Declare services in the NNS host, not the NoD configuration:

```nix
system.services.example = {
  process.argv = [ "/system/bin/sleep" "3600" ];
  process.environment.EXAMPLE = "value with spaces";
  nns.startAt = "unlock";
};
```

The `nns.startAt` and `nns.after` service fields control startup timing and
dependencies. Activation reconciles the root-owned runit directories and
restarts changed services. Services must stay in the foreground. Nested
services, `configData`, reload commands, and notification protocols are not
supported.

Configure SSH through `services.openssh`. Its state lives under
`/data/nix/var/nns`. OpenSSH runs unchanged with `StrictModes yes` and a
private `/var/empty` supplied by the launcher. App-owned authorized-key
files are read under the corresponding app's UID and GID.

The NoD module, exported as `nixOnDroidModules.nns`, only manages the app's
login, package profile, private configuration, terminal files, and Home
Manager activation. It always consumes the independent NNS system. It
cannot declare root services or shared daemon settings. Its sessions use
`NIX_REMOTE=daemon` and the NNS resolver bridge instead of proot or dnshack.
The KSU module publishes the `rish`, `su`, and `sudo` helpers.

`rish` uses Shizuku's permission-checked process API and an NNS terminal
supervisor written in Zig. The supervisor preserves terminal input, window
size, output streams, and shell exit status. It stops its process group when
the foreground shell exits. Input and window updates use a framed protocol
(messages with explicit types and lengths). Output streams remain unmodified.
The client does not use Shizuku's native terminal implementation or replace
its APK.

The boot module publishes the root-owned `/data/nix/bin/nns-rish-terminal`
helper and Android classpaths (lists of Java library files) in
`/data/nix/etc/android-runtime.env`. A private completion file prevents Java
startup failures from reporting success. No collector override or SELinux
relaxation is required on cheetah.

See [NNS systems and package profiles](../docs/nns-systems.md) for the module
API and deployment order. The terminal-ioctl workaround remains in
`libnns-dns.so`, described in [DNS and terminal support](src/DNS.md).

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
# or build the launcher from the repository root:
nix develop --command zig build nix-enter -Dtarget=aarch64-linux-musl -Doptimize=small
# the launcher is in zig-out/bin/nix-enter
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
