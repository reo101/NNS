# Native builds

Zig 0.17 compiles the core NNS native artifacts through the root
`build.zig`: the launcher, DNS bridge and resolver, terminal supervisor,
and experimental FIFO client. Nix fetches dependencies, selects targets, supplies headers,
and packages the results. APK, ROM, kernel, and Android platform fixture
builds remain in their existing build systems.

## Nix packages

```sh
nix build .#nns-native
nix build .#nix-enter .#nix-enter-host
nix build .#nns-dns
nix build .#checks.x86_64-linux.nns-native
nix run .#test-userns
```

`nns-native` builds the complete ARM64 core artifact set. The individual
packages still use separate derivations and source file sets. A launcher
build does not require the Android NDK.

`build.zig.zon` pins the official external `translate-c` package. Its pinned
`aro` dependency supplies the C parser. `nix/zig-dependencies.nix` fetches the
package archives with a fixed output hash and unpacks them into hash-named
directories. Each compilation uses `zig build --system` with that directory.
The compiler cannot download missing packages during a Nix build.

## Direct Zig builds

The development shell supplies Zig, Python, runit, and the fetched package
directory through `ZIG_LOCAL_PKG_DIR`.

```sh
nix develop
zig build nix-enter -Dtarget=aarch64-linux-musl -Doptimize=small
zig build test
zig build test-userns
```

Artifacts install under `zig-out/`. Use `--prefix` to select another directory.

| Step | Result | Additional input |
|---|---|---|
| `nix-enter` | Static launcher | None |
| `dns` | Bionic resolver and libc-neutral preload library | Android sysroot |
| `rish-terminal` | Android terminal supervisor | Android sysroot |
| `service-control` | Experimental runit FIFO client | None |
| `all` | All the above | Android sysroot |

`zig build` defaults to `all`. Pass `-Dandroid-sysroot=/path/to/sysroot`
for that step. A missing sysroot fails only the steps that require it.
`-Dtarget` selects the Linux target;
`-Darch=aarch64` or `-Darch=x86_64` selects the Android architecture.
`-Doptimize=small` selects stripped size-optimized builds.

## Tests

`test` runs the launcher ownership unit test, DNS tests, terminal tests,
and real-runit FIFO tests. Its individual steps are `test-nix-enter`,
`test-dns`, `test-rish-terminal`, and `test-service-control`.

`test-userns` runs separately because it needs user and mount namespaces.
The Nix runner builds the production host launcher in the sandbox and runs
these tests outside it. Android VM tests remain separate.

## Allocation ownership

Account registry parsing uses `BufferFirstAllocator` for temporary bytes.
It falls back to the caller allocator when the 4096-byte buffer is too small.
The returned account name belongs to the caller allocator, not that buffer.
A unit test uses `SafeAllocator` to check environment allocation ownership.

Exported DNS results still use caller-libc `calloc/free`. glibc frees the
preload library's results through `freeaddrinfo`; the Bionic resolver frees
its own results before it exits. A stateless allocator adapter can preserve
this contract if it returns libc-owned base pointers and satisfies alignment
requirements. An adapter can reject resize and remap operations. It must not
use a moving `realloc` call for an in-place resize.
Do not use a tracking allocator or a stack-backed allocator
for exported result storage. External libc deallocation bypasses their
ownership records.
