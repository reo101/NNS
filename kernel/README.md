# Cheetah kernel

This is an **ACK/GKI android14-6.1** build for Pixel 7 Pro, not the earlier
Sultan experiment. Linux release: `6.1.162`. Build host: `x86_64-linux`.

```sh
nix build .#kernel-cheetah
```

Output: `Image`, `config`, `System.map`, `vmlinux.symvers`, `kernel.release`,
and the ROM-specific `avb.json`. No vendor modules, DTB, ramdisk, ROM images,
private keys, or flashing operations are included.

For built-in Btrfs with POSIX ACL support, build the separate variant:

```sh
nix build .#kernel-cheetah-btrfs
```

The default `kernel-cheetah` keeps its existing feature selection.
Neither package formats, converts, or mounts `/data`.
The Btrfs variant requires its own boot and filesystem tests before deployment.
It passed temporary boot and installation to Cheetah's `boot_a` on 2026-10-22.
Tests covered file I/O, reflink copy-on-write, a read-only snapshot, remounting, and offline metadata and data checksum checks.
The Nix daemon, Wi-Fi and 321 loaded modules remained operational.
The vbmeta and inactive boot partition hashes did not change. Android `/data` remains F2FS.

Global SELinux stayed enforcing. Filesystem tests used the existing permissive `ksu` root domain, which does not block denied access.
The test filesystem was unlabeled. These results do not validate ordinary-app access or a Btrfs-backed Nix store.

## Root implementation

The current integration targets **SukiSU Ultra's official `builtin` branch**,
revision `b20dee702035af09cb2ecb5f35443bbc1747f3e6`. It replaces xxKSU; the two
implementations are not stacked. The build identity is pinned to
`v4.2.0-b20dee70@builtin-nns` / `40900`, without Makefile network or Git probes.
The installed SukiSU 4.1.3 manager's signing certificate was verified against
the trusted SukiSU certificate in this source. The Nix-built image booted on
slot A and that manager reported Working/GKI, driver 40900 and SuSFS 2.3.0.
It also reported its 40796/40900 version mismatch; matching manager 4.2.0 is
recommended. All 15,424 exported symbol CRCs matched the working xxKSU build.

KPM is left disabled, matching the source's default. This package does not
include the separate KernelPatch/KPM integration.

## Inputs and local patches

`sources.nix` fetches content-hashed archives for the pantah source release,
LLVM 17.0.6, SukiSU and SuSFS. There are no references to the old working
directory or its toolchains.

Only local adjustments live in `patches/`:

- `sukisu-version.patch`: remove build-time network/Git version discovery.
- `susfs-compat.patch`: adapt the **fetched upstream patch**, rather than vendor
  its entire contents. Account for ACK's extra namespace header; omit the
  obsolete Google-uname hunk; use the `fs/exec.c` hook from SuSFS revision
  `4fc9c1898ea66f51847cdbc0d1473ea4ef525a70`, matching SukiSU builtin's sucompat
  API. The rest of SuSFS remains at the current pinned revision, including its
  mount-race fix.
- `susfs-newuname.patch`, `susfs-taskmmu.patch`: the small ACK 6.1.162 API ports.

Patch application fails on rejects. The old xxKSU de-inlining and manual-LSM
hook patches are not used for SukiSU.

## Configuration and caching

`rom.config` is the recorded ROM parity base; `nns.config` enables USER_NS,
USB HID and the root/hiding features. Do not casually substitute `gki_defconfig`:
vendor-module ABI depends on configuration as well as compiler version.
SysV IPC remains disabled, as in the boot-tested configuration.

Android GKI export protection is disabled: this ROM ships unsigned GKI modules,
including `rfkill.ko`, that export names on the protected list. Leaving that
protection enabled rejects rfkill and prevents the Wi-Fi dependency chain from
loading. Normal module signature support remains enabled, but the CRC-forcing
patch and `MODULE_FORCE_LOAD` are removed. ABI mismatches must fail rather than
be hidden by forced loading. The repaired image was boot-tested with 321
modules loaded, the full rfkill/cfg80211/bcmdhd chain present, Wi-Fi associated,
and the Wi-Fi Settings screen responsive. No forced-load taint was present.

All target and host C/C++ commands pass through sccache. The resolved config
hash salts its cache key: `configs.c` embeds a gzip via assembler `.incbin`,
which is invisible to preprocessing-based cache validation. The final check
also compares the embedded config against the actual build config.

A sandboxed Nix build has a private, temporary sccache. It does not secretly
bind-mount `~/.cache/sccache` into the sandbox; Nix caches the complete output.
`nix develop .#kernel-cheetah` supplies matching tools and uses the user's
persistent cache for interactive work. Manual make invocations must set
`SCCACHE_C_CUSTOM_CACHE_BUSTER` to the resolved config's SHA-256 as well.

## Third-party kernel support contract

What does a kernel need so the NNS module (and its Emacs integration) work
on it? In order of invasiveness:

1. **`CONFIG_USER_NS=y`.** The generic part. Unprivileged app processes
   must be able to `unshare(CLONE_NEWUSER|CLONE_NEWNS)` and write their
   own uid/gid maps; `user.max_user_namespaces` must not be zero for
   app UIDs.

2. **Exec-time seccomp bypass.** Every zygote-spawned app process carries
   a seccomp allowlist that denies `mount(2)`, `pivot_root(2)` and
   friends; the filter survives a user-namespace unshare and cannot be
   removed from userspace. This kernel therefore exposes
   `/proc/sys/kernel/seccomp_bypass_paths`: root writes newline-separated
   absolute exec paths (max 8 x 128 bytes, exact match, 0600), and an
   `execveat()` of an exact match clears the calling task's seccomp
   filter. The NNS module registers its launcher there in
   `post-fs-data.sh`; any other rootless-namespace consumer can do the
   same. The check lives in `do_execveat_common()` (`nns-seccomp-bypass.patch`)
   and must run ahead of SuSFS's `no_su` early-exit, which otherwise skips
   the whole sucompat hook chain for unprivileged apps. The
   `disable_seccomp()` helper comes from SukiSU under `CONFIG_KSU`; a
   kernel without KSU must provide an equivalent filter-clearing helper.

3. **SELinux policy injection via the root manager.** The module's
   `sepolicy.rule` defines the `nns_app` domain and grants the namespace
   operations (see the file itself; every mount it performs stays inside
   the launcher's private namespace). Any root manager that can inject
   policy at boot from a module rule file works — ksud (KernelSU/SukiSU)
   and magiskpolicy (Magisk) both consume module `sepolicy.rule` files,
   with slightly different statement support.

SuSFS is not required, but when present its `no_su` mark on unprivileged
app processes is what forces the hook placement above. Without SuSFS the
same check can sit anywhere in the exec path.

## Boot image and AVB constraint

This profile is tied to the already-tested custom vbmeta:

- actual struct size: **6336 bytes**, not the 64 KiB partition padding;
- SHA-256: `51a13c62771ebba4a48b6300f43342f892b225b144eb3ea12767bbdcfd7309fb`;
- flags: **3**, verification/hashtree checking disabled.

An OTA or different vbmeta requires deliberate revalidation and new values.
This is not a generic image for every cheetah ROM.

```sh
nix run .#repack-boot -- \
  /path/to/stock-boot.img result/Image /path/to/new-boot.img \
  --vbmeta /path/to/matching-vbmeta.img
```

The repacker accepts kernel-only boot-v4 images, preserves the stock header,
checks the kernel/AVB profile, refuses to overwrite output files and emits a
plain image without an AVB footer. It does **not** flash or alter vbmeta.
The phone's ABL rejected footerized images in the original boot tests.

Keep a known-good boot image and the stock fallback slot. Restart the host adb
server before any bootloader operation. Flashing is an explicit separate step.
