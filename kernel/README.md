# Cheetah kernel

This is an **ACK/GKI android14-6.1** build for Pixel 7 Pro, not the earlier
Sultan experiment. Linux release: `6.1.162`. Build host: `x86_64-linux`.

```sh
nix build .#kernel-cheetah
```

Output: `Image`, `config`, `System.map`, `vmlinux.symvers`, `kernel.release`,
and the ROM-specific `avb.json`. No vendor modules, DTB, ramdisk, ROM images,
private keys, or flashing operations are included.

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
LLVM 17.0.6, SukiSU, SuSFS and the workflow's module-CRC compatibility patch.
There are no references to the old working directory or its toolchains.

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

All target and host C/C++ commands pass through sccache. The resolved config
hash salts its cache key: `configs.c` embeds a gzip via assembler `.incbin`,
which is invisible to preprocessing-based cache validation. The final check
also compares the embedded config against the actual build config.

A sandboxed Nix build has a private, temporary sccache. It does not secretly
bind-mount `~/.cache/sccache` into the sandbox; Nix caches the complete output.
`nix develop .#kernel-cheetah` supplies matching tools and uses the user's
persistent cache for interactive work. Manual make invocations must set
`SCCACHE_C_CUSTOM_CACHE_BUSTER` to the resolved config's SHA-256 as well.

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
