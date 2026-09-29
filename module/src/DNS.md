# Android DNS bridge

Build both ARM64 artifacts with Zig 0.16:

```
zig build -Doptimize=ReleaseSmall -Dandroid-sysroot=/path/to/ndk/toolchains/llvm/prebuilt/linux-x86_64/sysroot
zig build test
```

The first command installs `zig-out/bin/nns-resolver` and
`zig-out/lib/libnns-dns.so`. `build.zig` generates the Bionic libc descriptor
from the NDK sysroot, targets Android API 29's link stubs and uses Android's
normal `/system/bin/linker64` startup. Tests need Python 3, not the NDK.
`nix build .#nns-dns` supplies the pinned toolchain and runs those tests;
`nix build .#nns-module` packages both artifacts with the launcher.

`nix-enter` prepends the bridge to `LD_PRELOAD` when it exists under the selected
backing store's `lib` directory. It uses the physical `/data/...` path because
Android's system linker namespace disallows `/nix`. The launcher preserves
existing preloads, but the Nix-on-Droid login replaces them with the NNS bridge
so an inherited `dnshack` cannot override DNS resolution. The bridge has no libc
DT_NEEDED dependency: Bionic children delegate to their original `getaddrinfo`;
glibc children exec the helper with the same UID and a clean environment.
No shell, global environment mutation, DNS-server snapshot, `/etc` replacement,
public DNS fallback, or resolver daemon is involved.

The helper calls Bionic `getaddrinfo`. Flags and errors are translated; full
IPv4/IPv6 socket addresses, ports, scope IDs and canonical names cross a bounded
binary pipe protocol. Results use glibc-compatible allocations and its native
`freeaddrinfo`. Calls time out after 30 seconds and reap their helper.

Limits:
- Dynamic glibc `getaddrinfo` only, not static binaries, `gethostbyname`, reverse
  lookup, raw DNS APIs or programs with their own DNS implementation.
- Bionic decides lookup semantics. GNU IDN flags are rejected; Android versions
  that reject `AI_V4MAPPED`/`AI_ALL` still reject those explicit IPv6 requests.
- Up to 64 results and 255-byte canonical names. Overflow fails, never truncates.
- Exec preserves UID-based Android network policy, not an in-process Bionic
  network binding established in a different process. Root daemon lookups use
  the daemon's UID, not the app client's UID.
- Requires Linux `close_range` (5.9+), available on the project's Android kernel.

`NNS_DNS_HELPER` may override the helper's absolute path for testing; its default
is `/nix/bin/nns-resolver`. Missing or malformed helpers fail closed, with no
fallback to glibc's resolver.

## Terminal ioctl shim (same library)

`libnns-dns.so` also exports `ioctl`, `isatty`, `tcgetattr`, `tcsetattr` and
`ttyname`. Modern Android issues `TCGETS2`/`TCSETS2` on ptys; this kernel
answers those with `EACCES`, which sshd and glibc tooling read as "not a
terminal". The shim retries the legacy `TCGETS`/`TCSETS` struct on that error;
`ttyname` also uses the legacy check before reading `/proc/self/fd` because
glibc's internal `__tcgetattr` bypasses preload. It routes through the bridge
because ksud's sepolicy
parser drops `allowxperm` ioctl rules — granting the raw ioctl through policy
was not an option (one-domain-per-line rules survive ksud; brace-sourced
`type_transition` lists and `allowxperm` do not).

ABI references:
- https://github.com/ettom/dnshack (prior art; no source copied)
- https://github.com/aosp-mirror/platform_bionic/blob/master/libc/include/netdb.h
- https://github.com/bminor/glibc/blob/master/nss/getaddrinfo.c

## Shizuku rish property shim

The NNS user namespace maps the app UID but not host root, so Bionic sees
Android's root-owned `/dev/__properties__` files as `overflowuid`. Its property
loader rejects them despite read access. With `NNS_RISH_PROPERTY_INFO_SHIM=1`,
`libnns-dns.so` reports UID/GID 0 only for `fstat` calls on files directly in
that directory. SELinux still controls which property areas are readable. The
rish launcher sets this flag and preloads the library; ordinary processes are
unchanged.
