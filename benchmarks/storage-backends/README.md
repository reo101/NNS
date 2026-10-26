# Btrfs backing evaluation

## Decision

The module does not use Btrfs backing. Directory mode on `/data/nix` remains the
default and the deployed mode. The opt-in image backend stays implemented and
untested for production.

Two findings drive this. The image layer costs time on metadata-heavy work. More
importantly, `fsync` inside the loop-mounted filesystem does not reach the
backing device, so the backend has weaker durability than native F2FS. That
second finding is a correctness problem, not a tuning problem.

This document records measurements taken on the phone. It does not record a
deployment approval.

## Method

All measurements ran on cheetah, serial `27211FDH3004Q4`, kernel 6.1.162,
SELinux Enforcing. Each backend was a private Nix store, so no measurement wrote
to the live `/nix`.

- Test files: 128 MiB and 256 MiB.
- Image: 1 GiB single-device Btrfs, one subvolume, `compress=zstd:3` unless
  stated.
- Mount: loop device, `nosuid,nodev,nodiscard`.
- The scratch image used the existing `shell_data_file` test label and a
  permissive `ksu` mount. Kernel workers have no read grant on
  `system_data_file`. This label is a test artifact, not a production choice.
- Load average during runs was between 1.4 and 4.3. The phone was not idle.

Variance is significant. Repeated baseline runs of the same copy drifted between
9.6 s and 11.0 s. Treat differences under about 7 percent as noise. One
evaluation measurement drifted between 4.0 s and 32.7 s across runs under memory
pressure, so no evaluation ratio is claimed here.

## Launcher overhead

The launcher adds a fixed cost per process. It does not affect throughput.

| Path | Time per invocation |
|---|---:|
| Direct fork and exec | 10.8 ms |
| `nix-enter` | 27.3 ms |
| `nix-enter --userns` | 27.4 ms |

The user namespace adds nothing over the mount namespace. A build that starts
1000 processes pays about 16 seconds extra. File I/O through the launcher
matches direct access within noise.

## Filesystem comparison

Medians of three runs per cell. F2FS is the live tree. Btrfs is the scratch
image on the same device.

| Workload | F2FS | Btrfs | Ratio |
|---|---:|---:|---:|
| Sequential write, fsync | 176 MB/s | 203 MB/s | 0.89x |
| Sequential read, cache dropped | 1040 MB/s | 1138 MB/s | 0.84x |
| Sequential write zeros, fsync | 223 MB/s | 918 MB/s | 0.24x |
| 4K random writes, fdatasync each | 3190 IOPS | 234 IOPS | 13.7x slower |
| create, stat, unlink | 56k files/s | 44k files/s | 1.3x slower |

Bulk sequential work is equal or faster. Compressible data gains about four
times. Small synchronous writes lose an order of magnitude.

## Nix-shaped workloads

| Workload | F2FS | Btrfs | Ratio |
|---|---:|---:|---:|
| Database commit, 4K plus fdatasync | 1635/s | 288/s | 5.7x slower |
| Store extraction, 4000 small files | 38.9k files/s | 10.5k files/s | 3.7x slower |
| GC-style recursive delete | 48.0k files/s | 28.2k files/s | 1.7x slower |

Garbage collection is the mildest case. Database commits and small-file
extraction are worse.

## Real workload: nixpkgs flake and neovim

On F2FS, with a cold cache and a real download:

| Phase | Time |
|---|---:|
| Fetch `github:NixOS/nixpkgs/nixos-unstable` and evaluate `neovim.drvPath` | 2.32 s |
| Substitute neovim, 116 paths, 299 MB of nar data | 3.24 s |
| Total | 5.62 s |

The network cost is identical on both backends. Only the write path differs.
Copying the same closure from a local reference store, with the network
excluded:

| Operation | F2FS | Btrfs |
|---|---:|---:|
| Closure, 116 paths | 3.1 s | 10.2 s |
| Nixpkgs source, one path, 100k files | 38.9 s | 33.7 s |
| Register one small path | about 100 ms | about 105 ms |

Per-path registration is identical. The cost scales with the number of paths
whose data must be flushed, not with the number of transactions or with total
bytes. One large path is not slower on Btrfs.

## Mount option variants

Real `nix copy` of the neovim closure, three rounds, same conditions. Space is
the image usage after the copy.

| Options | Copy time | Space | Speed |
|---|---:|---:|---:|
| `compress=zstd:3` | 10180 ms | 155 MB | 1.0x |
| `compress=zstd:1` | 7960 ms | 159 MB | 1.28x |
| `compress=zstd:3,nobarrier` | 10040 ms | 157 MB | 1.01x |
| `nodatacow,nodatasum` | 6050 ms | 341 MB | 1.68x |
| `nodatacow,nodatasum,nobarrier` | 5300 ms | 341 MB | 1.92x |
| `nossd` | 10180 ms | not measured | 1.0x |
| `ssd_spread` | 10400 ms | not measured | 1.0x |

`compress=zstd:1` is faster than `zstd:3` at equal space. `nobarrier` alone does
nothing. `nodatacow` is the largest gain, at 2.15 times the space.

## What remains after nodatacow

`nodatacow` removes copy-on-write for data extents. Filesystem metadata is still
copy-on-write. Measured with `nodatacow,nodatasum,nobarrier`:

| Workload | F2FS | Btrfs nodatacow | Ratio |
|---|---:|---:|---:|
| Create 4000 files in directories | 57k files/s | 17k files/s | 3.3x slower |
| create, stat, unlink | 32.6k files/s | 20.0k files/s | 1.6x slower |
| Recursive delete | 47k files/s | 47k files/s | equal |

Creating files remains the residual cost. Deleting files does not.

## fsync durability

`fsync` inside the loop-mounted Btrfs does not flush to the backing file.

- A 256 MB write with `fsync` inside the mount left 256 MB dirty in the host
  page cache.
- A later global `sync` took 1.1 s to flush it.
- `LOOP_SET_DIRECT_IO` fails with `EINVAL` on this F2FS backing, so direct I/O
  cannot close the gap.

This has three consequences.

1. The `nodatacow` numbers for fsync-heavy work are optimistic. They measure
   work that was not flushed.
2. A successful `fsync` does not mean the data reached flash.
3. Btrfs relies on flush and FUA ordering. If the loop layer does not honour
   preflush, a power cut can leave the filesystem inconsistent rather than
   merely missing recent writes.

No power-cut test has run. Crash safety of this backend is unproven.

## Interpretation

The namespace layer is not the problem. The filesystem layer is.

Btrfs is not uniformly slower. Large sequential reads and writes are equal or
better, and compressible content gains. The losses concentrate in two places:
small synchronous writes, and filesystem metadata updates.

For Nix, that means a build dominated by fetching and unpacking large store
paths stays neutral or improves. A build dominated by many small paths, or by
database activity, gets slower by seconds per ten thousand operations.

## Options if work resumes

1. Keep the Nix database on native F2FS and place only `/nix/store` in the
   image. The database is what needs `fsync` semantics. Store paths are
   immutable and verified against nar hashes.
2. Place the image on a real block device instead of a file on F2FS. Flush then
   works normally. Android has no spare partition, so this needs a partition
   decision.
3. Accept the durability gap and record it. Store data is rebuildable.
   Metadata corruption after power loss is not.

`compress=zstd:1` is worth keeping in any case. It is a free speed gain with no
space cost and no change in semantics.

## Open questions

- Does a power cut corrupt the image, or only lose recent writes? Requires a
  crash test.
- Does a 100 GB image behave like the 1 GiB test image, or worse once it
  fragments? The space penalty of `nodatacow` grows with the image.
- Does `fscrypt` on the backing file change the numbers? A device-encrypted
  directory measured within noise at this size, but only one run was taken.
- Does the database-only split in option 1 remove the commit penalty in
  practice? Not measured.

## Reproducing

The fixtures stay in this directory:

- `throughput-probe.zig` measures sequential write and
  read, 4K random writes, database-style appends, store extraction, recursive
  deletion and launcher startup.
- `bench-mount.zig` mounts a scratch image with chosen
  options and can request loop direct I/O.
- `throughput.nix` builds the probe for the phone.
- `bench-image.nix` builds a labelled scratch image.

The driver scripts were ad hoc and are not in the tree. The shape is: build the
probe, mount the image with `bench-mount attach`, run the probe against the
mountpoint, then compare with the same probe against a directory on the live
tree. Use a private store with `nix --store` for any real Nix work.

`throughput.nix` stages both sources beside `build.zig`'s declared paths before
it compiles, so build through that derivation rather than calling `zig build`
directly.

```sh
nix build --impure --expr 'let f = builtins.getFlake (toString ./.);
  pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; };
  storage = pkgs.callPackage ./nix/storage.nix { }; in
  import ./benchmarks/storage-backends/throughput.nix { inherit pkgs storage; }'
```

## Evidence

`~/.local/state/nns-rom/module-btrfs/implementation/throughput/`:

- `phone-f2fs-run.log`, `phone-f2fs-reps.log`
- `phone-btrfs-run.log`, `phone-btrfs-reps.log`
- `phone-btrfs-fscrypt-reps.log`
- `phone-workloads.log`
- `phone-mount-options.log`
- `realworld-f2fs-a2.log`, `realworld-btrfs.log`
- `realworld-local-copies.log`, `realworld-per-path.log`
- `tuning-variants-round1.log`, `tuning-variants-round2.log`,
  `tuning-variants-round3.log`
- `residual-after-nodatacow.log`
- `fsync-durability.log`, `loop-direct-io.log`
- `status.json`, `summarize.py`, `summarize-variants.py`

## Corrected claims

Two statements made during the investigation were wrong and are corrected here.

- `noacl` has no effect on sequential throughput, and `compress=zstd:1` is
  faster than `zstd:3` on writes, not slower. Measured directly.
- An early end-to-end Btrfs figure of 41.6 s included a cold network fetch and
  is not comparable with the 5.62 s F2FS figure. The fair comparison excludes
  the network, as shown above.
