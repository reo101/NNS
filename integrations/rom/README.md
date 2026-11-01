# ROM-level canonical Nix mount experiment

## Current direction

The Cheetah NNS OTA passed its native build and package inspection. The
Cuttlefish NNS image passed enforcing mount and refusal tests. Cheetah ROM
hardware boot remains untested. Its candidate OTA still uses the upstream
kernel, not the separately installed NNS/Btrfs kernel.

The module selects ROM-owned mounting through `ro.nns.mount.owner=init`.
Host regressions and enforcing Cuttlefish checks pass for the property, init's
mount namespace, helper `--check` and refusal of property writes. Actual module
startup through an Android root manager remains untested. The Cheetah OTA
predates this interface.

The isolated signing lab preserved fixture data and existing keystore keys
across a signer change with a distinct build identity, then across another
reboot. Phone OTA trust, hardware keys and boot acceptance remain unverified.
See [Cheetah upgrade compatibility](cheetah-upgrade.md).
ARM translation and Digitalis remain deferred.

Jeeves has a separate baseline checkout under
`/home/jeeves/Builds/nns-rom/upstream-baseline/source`. Verification passed for all
1,185 locked project revisions and 112 LFS objects. Init and the nine previously
excluded overlay definitions match their originals; no NNS integration is
installed. The selected Cheetah device/vendor/kernel project paths match the
device dependency chain.

Repo's native local detached force-checkout restored an interrupted Clang
checkout, and whole-tree `repo status` subsequently confirmed a clean worktree.
The unmodified build then reproduced the generic/device overlay collision at
Make export. The user authorized fixing this ROM baseline separately from NNS.

`baseline-patches/gs201-overlay-selection.patch` changes only
`device/google/gs201/common.mk`: its `PRODUCT_SOURCE_ROOT_DIRS` excludes the nine
colliding generic overlay directories, retaining the device overlays and all
other Pixel-style overlays. No overlay `Android.bp` is modified. Exclusion paths
end in `/` because Blueprint uses raw prefix matching; otherwise excluding
`PixelConfigOverlay2019` would also remove `PixelConfigOverlay2019Midyear`.
`python3 tests/test-rom-baseline-patches.py` checks those boundaries.
The reviewed original common product SHA256 is
`9fc38003cea257d9cb7abd6096151acb49de8015b7ce6e0d39e900338f36ed9b`.
This is now a ROM-only baseline with one declared compatibility patch, not an
unmodified-source success. NNS remains absent.

The one-off host job `nns-rom-upstream-build.service` invokes upstream's
`lineage_cheetah-bp4a-userdebug` and `m -j8 SELINUX_IGNORE_NEVERALLOWS=false evolution`
path. Before retrying, the job accepts exactly the reviewed common product
change and refuses any other tracked checkout difference. The patched SHA256 is
`68bca8b8fa352c24e5f3f7341b03149b0a5d9ced959a4528bf826c8d473f98a0`.
Generated Make exports confirmed all nine device overlays selected, with
`PixelConfigOverlay2019Midyear`, `PixelConfigOverlay2018` and
`GoogleSystemUIOverlay` retained from Pixel-style. Make and packaging-rule
generation passed; evidence is in `upstream-baseline/overlay-selection-verification.json`.

The retry then failed at Ninja startup on missing
`device/google/pantah-kernels/6.1/gzvm.ko`. The earlier claim that this checkout
contained pinned Cheetah kernel binaries was incorrect: the pinned kernel
project contains only load/configuration metadata. Both checkouts initially
lacked the referenced modules. `TARGET_NO_KERNEL=true`
means this ROM consumes externally produced kernel artifacts; it does not prove
those artifacts exist. Upstream's `lunch` normally builds a separate kernel tree
and copies its outputs into that directory. `SKIP_KERNEL_BUILD=true` prevented
that production step. The user initially required published prebuilts, then
authorized running upstream's kernel producer once and retaining its output.

The separate kernel checkout now has a resolved source lock in
`upstream-baseline/kernel-source-manifest.xml`, SHA256
`e248802b89c575e37cc035cbfc0ca6130b7bdd61f6004a5d5e39b2cc79ce3876`.
The native kernel build passed in 209 seconds after adding `gcc.cc`, `glibc.dev`
and `openssl.dev` to the Nix host environment, following robotnix's host dependencies.
Upstream uses downloaded GKI artifacts and builds the device-specific components.
Its source lock remained unchanged. All required modules are present among 328
modules. `upstream-baseline/kernel-artifacts.json` records the complete output
hashes and host environment. Imported files match that output. The complete
output is retained outside the checkout in `upstream-baseline/kernel-prebuilts/`.
The ROM build reuses these artifacts with kernel compilation and synchronization
both disabled.

Recovery PNG generation later failed because the JDK could not load
`libfreetype.so.6`. Adding `freetype` and `fontconfig` to the Nix host environment
fixed the generator. The incremental retry completed all 11,566 remaining actions
in 53 minutes 26 seconds, excluding the separate source checks.

The native `m evolution` baseline build and package checks passed. The retained
OTA is `upstream-baseline/artifacts/EvolutionX-16.0-20261021-cheetah-11.11-Unofficial.zip`,
3,263,720,756 bytes, SHA256
`f55e471d28b2038f46990ab7fed99a7fc9ecbaf8eeb740750c8d2764b7e6e04b`.
`upstream-baseline/package-verification.json` records ZIP checksums, Cheetah A/B
metadata, and AVB chain checks on images extracted from the actual OTA.
The packaged unsigned boot content and kernel match the retained upstream output.
Packaging updates AVB signing properties, so the complete boot image differs from
the loose build intermediate. The native neverallow check produced its checked
policy, and NNS remains absent.

This is a userdebug build signed with public test keys, not a production release.
The OTA fingerprint reports `user/release-keys`, which does not establish signing
identity. AVB checks establish image-chain consistency, not device trust or boot
success. No flashing or boot validation occurred.

The official LineageOS 23.2 Cheetah release dated 2026-10-06 is quarantined under
`upstream-baseline/temporary/kernel-prebuilt-research/`. Its OTA, boot, DTBO,
vendor-kernel-boot and source manifest match the official published sizes and
SHA256 values. Its kernel metadata project matches our exact pinned revision;
its device-tree revisions differ. Extracted kernel release is
`6.1.145-android14-11-gedaaac4d5c85-ab16017558`, with KVM and MODVERSIONS enabled.
All required module names are present among 328 distinct modules. The 59 GKI
module byte variants across partitions differ only by appended signatures;
the shipped FIPS module reports an older 6.1.75 release in the same Android14-11
KMI family. Symbol CRC compatibility and signatures have not been independently
verified, and no runtime compatibility is established. This candidate is not
accepted into the baseline. Provenance and inspection records are
`candidate-source-comparison.json` and `candidate-binary-verification.json` in
that quarantine directory.
Status, correction provenance and output are recorded in
`upstream-baseline/build-status.json`, `upstream-baseline/baseline-correction.json`
and `upstream-baseline/logs/build.log`. The baseline is ready for NNS integration.

Experimental integration, not a boot-validated Cheetah image or flashing procedure.
The ROM provides `/nix`; Android init runs a static helper that binds persistent
`/data/nix` onto it. The existing KernelSU module still owns store provisioning,
the daemon, session launcher, resolver and services. No global root pivot.

## Contract

- `/nix` must be a real directory supplied by the system image.
- Missing `/data/nix` is created as `root:root`, mode `0755`. Only this backing
  directory is created; the existing module provisions its children.
- Existing backing contents, ownership, permissions, labels and fscrypt policy
  are not changed. Fresh creation inherits the parent's policy, corresponding
  to Android init's `encryption=None`, not `Require` or `DeleteIfNecessary`.
- One mount whose root has the backing directory's device/inode and matching
  read-only, nosuid, nodev and noexec flags is retained. Flag mismatches are
  refused, not remounted. Concurrent helper invocations serialize on
  the backing directory inode, without a lock file.
- Symlinks, nondirectories, inaccessible backing directories, conflicting or
  stacked mounts, and nonempty unmounted targets are refused without deleting
  data or unmounting anything. A backing directory created successfully before
  a subsequent mount failure is retained for the next attempt.
- The helper has no fscrypt mutation, store file-write, Nix-daemon, namespace,
  root-pivot, or unmount implementation. It binds in the namespace supplied by
  init and exits. It is not a repair utility for arbitrary broken mount trees.

The inode lock serializes cooperating helper invocations, not unrelated
privileged filesystem changes. The bind syscall uses descriptor paths for the
validated source and target. Replacing the source pathname does not redirect
that bind to an unvalidated replacement. This does not freeze ancestor paths or
establish every possible target or mount-stack race guarantee.

`nns-mount --check` runs the same existing-bind checks without creating backing
or mounting. An absent, conflicting or flag-mismatched bind fails. This mode
checks the caller's namespace. The module first requires that namespace to
match init's namespace.

This preservation contract applies to the helper. With
`ro.nns.mount.owner=init`, the updated module skips backing/store-root repairs
and the legacy bulk relabel pass. It still updates module-owned runtime files.
Those writes and Android's own restorecon remain outside the helper's metadata
preservation guarantee. Without the property, legacy module repair stays enabled.

The `nns_mount` SELinux domain has `sys_admin` for the bind and directory
read/lock/mountpoint permissions, not directory creation or DAC-bypass capabilities. The service runs
as UID/GID root with supplementary group system, because Android's `/data` is
`system:system 0771`. This permits traversal without DAC bypass. Creation is
performed by the creation-only `nns_prepare_backing` init builtin, not this domain;
Android's `/data` root neverallows remain unchanged. It is not the `ksu` domain, so the pinned SuSFS
patch's early KSU-specific mount-ID allocation should not classify this bind as
hidden. That distinction still needs a Cheetah/SuSFS runtime test.

## ROM wiring

Place this directory in the ROM source tree and select its location explicitly:

```make
# Device BoardConfig.mk
NNS_ROM_PATH := path/to/integrations/rom
include $(NNS_ROM_PATH)/BoardConfig.mk

# Device product makefile (parsed before BoardConfig.mk)
$(call inherit-product,path/to/integrations/rom/product.mk)
```

The init platform extension is required as well as the fragments above. For the
pinned candidate, `build-cheetah.py` applies the hash-guarded `init-extension.json`
changes to init's builtin map and library dependencies. Other ROM baselines need
an explicitly reviewed equivalent patch; copying only the RC is insufficient.

`Android.bp` builds the helper and shared preparation code using the platform's
static C runtime and installs its init fragment. Init calls label-aware native
`make_dir` only for absent backing, without `ParseMkdir`, metadata repair or
fscrypt mutation. The shared preflight validates the real, empty, unmounted
target before creating absent backing. Existing backing is opened without
following symlinks and retained unchanged. The mount service uses the same
preflight with creation disabled. Preparation performs no bind and returns
errors to init instead of terminating PID 1. The BoardConfig fragment adds the root mountpoint and private
system_ext SELinux policy. The file contexts align `/nix` with the existing
`system_data_file` backing labels, and give only the helper its entrypoint type.

Build and inspect the actual system/system_ext images and compiled policy before
considering deployment. Validate against the exact ROM manifest and vendor inputs;
the public EvolutionX revisions used for research are not its published build
manifest. The repository's pinned ROM policy baseline is not a replacement for
compiling these additions with that full tree and its neverallow checks.

## Cheetah source-build preflight

The public `bka` manifest currently describes Android 16 QPR2, with LineageOS
`lineage-23.2` and AOSP `android-16.0.0_r4` inputs. Its manifest commit postdates
`EvolutionX-16.0-20260808-cheetah-11.10-Official`; these are candidate public
build inputs, not a reconstruction of that OTA. Pinning the manifest repository
alone does not pin the projects it references. A successful source sync must
export a revision-resolved manifest, including local device/vendor projects,
before this can be called a reproducible source baseline.

Resolved candidate repository heads:

| Repository | Revision |
| --- | --- |
| `Evolution-X/manifest` | `871b8e82353de09027c69b8479324a41f02c976e` |
| `Evolution-X/build` | `d029f2917532024a5d5788cf024c0067eaf88e23` |
| `Evolution-X/build_soong` | `8dc46958b4c2614bdfe5250cde4d0642a1d5d231` |
| `Evolution-X/system_sepolicy` | `e631d35d7bd7b7993e84f3d49eeb34ec87dd1a27` |
| `Evolution-X-Devices/device_google_cheetah` | `bcbebf6963ead3404cc3d676f88feb4e5c1698af` |
| `Evolution-X-Devices/device_google_pantah` | `ddbe96d217dfc7a217311a6ef1b2fd43b3fd4f6a` |
| `Evolution-X-Devices/device_google_gs201` | `ee46554b1746800c16561c0e9b00d4d79b830cdc` |
| `Evolution-X-Devices/device_google_gs-common` | `52b4e62c80f982e895da2b13b6421e1055423b4d` |
| `Evolution-X-Devices/vendor_google_cheetah` | `2c981fe0f0be5e61c24f76d287f223a21a813497` |
| `LineageOS/android_device_google_pantah-kernels` | `bc7dd5505feae60e4fa29da161a3595e97d3c689` |

The Cheetah repository supplies dependency declarations; `lineage_cheetah` is
actually declared in `device/google/pantah`. Its dependencies include `gs201`,
`gs-common`, Cheetah vendor blobs and the `lineage-23.2` pantah kernel prebuilts.
The public manifest's documented release configuration is `bp4a`. The vendor
revision imports `BP4A.251205.006` blobs and firmware, matching the device product's
build-description override. This does not establish the installed ROM's inputs.

Large vendor files use the LFS endpoint declared in the vendor repository:
`https://git.evolution-x.org/Evolution-X-LFS/blobs.git/info/lfs`. An unauthenticated
batch request and one-byte ranged download of the camera HAL APEX succeeded;
this checks endpoint access, not availability or integrity of every vendor blob.

Source inspection also caught and corrected an ignored policy-directory variable:
EvolutionX's `core/soong_config.mk` exports `SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS`,
not `BOARD_SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS`. A make-variable check now confirms
that the fragment supplies the policy directory and root folder. Actual Soong
and Make generation subsequently passed. Production compilation caught the
original helper's forbidden `/data` write/add_name grants; creation has therefore
moved into init rather than adding a platform neverallow exception. The revised
policy has passed production neverallow checks with the platform `init.te`
unchanged. Init's shared C preparation implementation must be included through
`libinit_defaults.whole_static_libs`, not only its header-visible static dependency.
The revised creation-only init builtin, static AArch64 helper, installed RC,
compiled domain transition/file contexts and production neverallow output have
passed the build driver's first gate. Genuine source-built system/system_ext
images have also passed read-only content and metadata inspection. Boot validation
remains pending.

## Remote source workspace

Validation uses Jeeves, an x86_64 NixOS host with 32 CPUs, 61 GiB RAM and usable
KVM. Its initial free space was 771 GiB on the shared home/data/Nix-store
filesystem. Source, logs and build outputs stay under
`/home/jeeves/Builds/nns-rom`; no phone connection or system reconfiguration is
needed. The NNS working-copy export is in the `integration` subdirectory.

From that integration export, build the pinned Nix FHS environment:

```sh
nix build --builders '' --out-link ../environment .#nns-rom-build-environment
../environment/bin/nns-rom-build-environment -c 'python3 integrations/rom/sync-cheetah.py /home/jeeves/Builds/nns-rom'
```

The environment provides conventional Bash/loader paths for Android's build
tools without adding global FHS mounts. It scopes the required HTTP user agent
to Git/curl downloads and patches Git LFS's otherwise hardcoded user agent.
JDK and target compiler prebuilts come from the Android checkout.

`sync-cheetah.py` initializes a shallow checkout at the candidate manifest
revision, installs `cheetah-source.xml`, then syncs with four workers. The local
manifest pins device/vendor/kernel inputs and the build/Soong/platform-policy
repositories; remaining branch-based projects are resolved during sync. Only a
successful sync exports the complete `source-manifest.xml` revision lock.
The driver checks free space before and every 15 seconds during each command,
stopping the command if free space drops below 150 GiB. Its regression check is
`python3 tests/test-rom-source-sync.py`.

Run long operations as transient user services so SSH disconnection does not
terminate them. `nns-rom-source-sync.service` performs the sync;
`nns-rom-cheetah-build.service` runs the queued build driver:

```sh
../environment/bin/nns-rom-build-environment -c 'python3 integrations/rom/build-cheetah.py /home/jeeves/Builds/nns-rom'
```

The driver waits for the source service to finish successfully, requires resolved
project revisions matching the pinned inputs, and compares a fresh checkout
manifest with the sync lock. It copies only the production fragment into
`external/nns-rom`, adds product/BoardConfig includes once, and records input
hashes in `build-inputs.json`. Outputs stay in `out-cheetah`; logs stay in
`logs/cheetah-build.log`. The queued service has the same 40/44 GiB memory
high/maximum limits and reduced scheduling priority as the source service.

The first eight-job build explicitly requests `init_second_stage`, `nns-mount`, `selinux_policy` and
`sepolicy_neverallows` for `lineage_cheetah-bp4a-user`, with
`SELINUX_IGNORE_NEVERALLOWS=false`. Before building images, the driver verifies
Soong's effective neverallow setting and policy-directory input, a static
AArch64 helper, presence of the creation-only builtin in compiled init, the
unchanged installed init fragment, compiled helper domain
and init transition, file contexts, and the neverallow test's real binary policy
output. Only then does it request `systemimage`, `systemextimage` and the host
`simg2img` tool, repeating the compilation checks afterward. SELinux neverallow
checks remain enabled. The driver sets upstream `SKIP_KERNEL_BUILD=true` to
preserve the pinned kernel prebuilts rather than let lunch download/build an
additional kernel and replace them. The FHS environment provides ccache; its
cache stays under the workspace with a 50 GB size limit.

The driver regression (`python3 tests/test-rom-build.py`) checks resolved-source
rejection, repeat-safe wiring, fresh/dangling output-directory setup,
disabled-neverallow/missing-policy rejection and failed-sync refusal. Driver checks have passed locally and in Jeeves's FHS
environment. The actual init/helper/policy compilation and genuine image
inspection gates have passed; the boot phase is not yet validated.

After building images, `inspect-cheetah.py` opens them read-only with `debugfs`.
Android sparse images are converted into temporary raw copies using the
source-built host tool. It checks empty `/nix`, root/root `0755` metadata and
`system_data_file` label; the helper's Android-standard root/shell (`0:2000`)
`0755` executable metadata and `nns_mount_exec` label; compiled init's same
root/shell executable metadata and `init_exec` label;
and byte equality of packaged init/helper binaries, init fragment, CIL and file
contexts against the already verified staging outputs. Temporary raw copies are
removed afterward. It does not mount images, execute the helper or contact a
phone.

Its disposable raw/sparse ext4 regression checks that inspection does not change
input images and rejects wrong owners/groups, mountpoint mode/label and occupied targets:

```sh
nix shell nixpkgs#android-tools nixpkgs#e2fsprogs -c python3 tests/test-rom-images.py
```

These inspector checks have passed locally and on Jeeves. Source synchronization
has also completed: `source-manifest.xml` records 1,185 projects, with SHA256
`29ffff9c5ca5243106d7ce2b4f181e19705ff7a904cfdf3cefe4ef40cfb29bd5`.
Repo omits `path` when it equals the project name; the validator accounts for
that default and has validated the actual exported lock.

A subsequent Soong graph pass found a missing WebView LFS object despite Repo's
successful sync. The driver now runs `verify-source-lfs.py` before compilation:
it enumerates LFS pointers at the locked revisions, installs the current local
LFS filter, fetches those exact revisions, checks out missing objects, and checks
every object's size and SHA256. Literal pointers in source projects without any
LFS tracking rules remain Git content, not download requests. If an interrupted
initial checkout left a missing indexed file, the driver materializes that
missing file through LFS smudge after fetching its locked object. Existing
mismatched content is refused, not overwritten. It writes the object inventory
to `source-lfs.json` only after success and records its hash in `build-inputs.json`.
No project revision is changed. The actual inventory has passed: 112 objects in
six projects, totaling 4,576,555,363 bytes; inventory SHA256
`c8a59be2487829f64fe999914eed331f7cabc902cc46dd58b635ac501fe29812`.

Source-build corrections also include a source-relative `out-cheetah` symlink to
the workspace output directory: the upstream test-package graph rejects absolute
output paths. The shared output setup creates the destination before lunch and
recovers an existing matching dangling symlink; otherwise `mkdir -p` fails and
lunch misleadingly reports a missing product. Conflicting paths are refused.
Product artifact enforcement remains enabled, with exact allowed
entries for `system/bin/nns-mount` and its init fragment only.

This candidate additionally needs a user-approved upstream baseline patch:
keep device-specific overlays instead of conflicting generic `vendor/pixel-style`
modules. A collision inventory identified nine shared module names, recorded with
reviewed source hashes in `cheetah-overlay-exclusions.json`. The resources differ
and exporting both definitions prevents Make generation. The driver requires
each device counterpart, refuses an unexpected generic definition, excludes the
generic definitions idempotently and records resulting hashes in `build-inputs.json`.
This is not an unmodified upstream ROM baseline.

The Cheetah system/system_ext build completed all 169,200 steps. Its first
inspection rejected Android-standard root/shell binary groups because the checker
incorrectly required root/root. The corrected checker requires the exact `0:2000`
binary ownership and retains `0:0` for `/nix`; no image was rebuilt or modified.
Compilation, labels, modes, ownership, empty mountpoint and packaged byte-equality
checks now pass. Jeeves records the corrected inspector digest, original build
input digest and unchanged image hashes in `cheetah-image-checks.json`:

| Image | Bytes | SHA256 |
| --- | ---: | --- |
| `system.img` | 1,162,248,192 | `7cceab77b8e00a399d4f576388aca4da782a2ec76d949cdad790a7d3aa218d01` |
| `system_ext.img` | 1,068,564,480 | `cf70bf29d9bab97638b0ba071e856d0c5b86f8f78d52933f5a50f1aa048343c5` |

The verification log is `logs/cheetah-image-checks.log`. Source-built enforcing
boot, backing-preservation runtime assertions and hardware/SuSFS testing remain
pending. Successful image inspection alone is not boot-safety evidence.

## Source-built Cuttlefish lab

### Current baseline

The current build uses `lineage_cf_phone_x86_64-bp4a-userdebug` without NNS.
It uses the same 1,185 pinned project revisions as the completed Cheetah baseline.
The retained VM workspace is `/home/jeeves/Builds/nns-rom/source` on Jeeves.
The Cheetah baseline checkout and its retained OTA remain separate.

`baseline-patches/cuttlefish-test-profile.patch` changes four tracked files:

- Selects ext4 system images in the virtual product.
- Excludes FaceUnlock packages, properties, permissions and module definitions
  from this virtual product. Other products retain FaceUnlock.
- Removes the absent proprietary confirmation-UI namespace from the virtual board.
- Restricts the radio `su` socket grant to debug builds. Platform neverallows remain unchanged.

A separate correction, `baseline-patches/audio-effect-factory-lock.patch`, adds
one mutex guard to the hardcoded ViPER effect initializer. The example audio HAL
failed its thread-safety check without that guard. Warnings-as-errors remain enabled.
This correction applies only to the VM checkout, not the retained Cheetah baseline.

`baseline-patches/cuttlefish-google-split-permission.patch` omits one unused Google permission mapping from the virtual product.
The VM lacks GMSCore, which normally declares the mapping's source permission.
PackageManager aborts with `Unknown source permission com.google.android.gms.permission.ACTIVITY_RECOGNITION in split permissions` when that mapping is present.
Other products retain the mapping. The incremental correction retains compiled objects and removes only the obsolete generated XML from VM staging.
Its build log is `logs/cuttlefish-google-permission-build.log`.

The Trusty security-VM action also needs Nix host dependencies inside its nested
`nsjail`. The user selected a read-only bind of the entire `/nix/store`.
`baseline-patches/nix-nsjail-store.patch` adds that bind and retains the jail.
It also binds `/etc/ld.so.cache` read-only for FHS library lookup.
Without that cache, Trusty's `libclang` cannot find `libz.so.1`.
The original jail failed to execute `/bin/bash` because its absolute Nix store
paths were absent. A small jail test reproduces the failure and passes with the bind.
`baseline-patches/trusty-build-job-limit.patch` limits nested Make to eight jobs.
Without this limit, the Trusty script defaults to the host CPU count, not Ninja's job limit.

`baseline-patches/soong-go-memory-limit.patch` forwards only `GOMEMLIMIT` into the cleared environment of `soong_build`.
Without this patch, its `env -i` launcher discards the exported memory budget.
The managed rebuild uses `GOMEMLIMIT=24GiB` and retains a separate 32 GiB hard cap.
The running builder's environment and eight-CPU affinity were inspected directly.
The managed job runs image inspection after compilation and records timeout or cancellation through `ExecStopPost`.

Removing FaceUnlock from `PRODUCT_PACKAGES` alone is insufficient.
Android also validates dependencies of unselected module definitions.
The virtual product therefore excludes `packages/apps/FaceUnlock/Android.bp`
through `PRODUCT_SOURCE_ROOT_DIRS`. The nested AIDL interfaces remain available
because the framework requires them. No translation library or dependency waiver is added.

The old experiment's source changes and three incomplete WebView checkouts were
archived before restoration. Native Repo restored the three missing WebView indexes.
The VM staging directories were cleared once with `m installclean`.
Compiled objects, the shared 50 GB compiler cache and Cheetah outputs were retained.
The preflight passed for the pinned kernel and 142 x86_64 kernel modules.

The native build command is:

```sh
. build/envsetup.sh
lunch lineage_cf_phone_x86_64-bp4a-userdebug
m -j8 SELINUX_IGNORE_NEVERALLOWS=false droid hosttar
```

The managed job sets `OUT_DIR=out-cuttlefish` and `SKIP_KERNEL_BUILD=true`.
Its records are `cuttlefish-baseline-source-status.json`,
`cuttlefish-baseline-build-status.json` and `temporary/cuttlefish-baseline/`.
Its log is `logs/cuttlefish-baseline-build.log`.
The final incremental build completed in 58m31s across 31,345 remaining actions.
The initial post-check incorrectly scanned the retained compiled-object cache.
Its only NNS match was `obj/EXECUTABLES/nns-mount_intermediates/nns-mount`, not an installed file.
The corrected check scans installed staging trees and inspects the actual ext4 images.
It passed for stock x86_64 init, absent NNS paths and policy types, absent FaceUnlock,
and the pinned virtual-device kernel.
The record is `temporary/cuttlefish-baseline/artifact-verification.json`.
Reflink snapshots are retained under `cuttlefish-baseline/images/` and `cuttlefish-baseline/artifacts/`.

The first boot attempts stopped in the host launcher, before the VM started.
The host package requires `ANDROID_HOST_OUT` to locate its configuration independently of `HOME`.
It also calls `/usr/lib/cuttlefish-common/bin/capability_query.py`, which the build FHS environment lacks.
`nix/cuttlefish-runtime-environment.nix` supplies the upstream helper in a separate runtime environment.
The helper is pinned to commit `8d08b814f3484d183bb827f5a5c2dd095dab44c8`.
It advertises package capabilities, not hardware readiness. KVM and vhost-vsock access passed separately.
The original build environment remains unchanged.
Cuttlefish also requires `cvdnetwork` for directory ownership, even with TAP disabled.
The user selected a runtime-local alias to the existing GID 100. The host group database remains unchanged.
The runtime hides the host nscd (name-service cache daemon) socket, so group lookup uses its own group database.
The `runtimeGroupFile` input contains the host group database with `cvdnetwork:x:100:` appended.
VM state and temporary parent directories use mode `0700`. Simulator services with wildcard TCP listeners are disabled.

Jeeves reset without a clean shutdown during a VM test on host kernel 7.2.2.
No saved panic, OOM event or persistent crash record explains that reset.
The next host boot used kernel 7.3.0. A six-minute retry did not reset the host.
It exposed the PackageManager failure above. Host Wi-Fi driver warnings also occurred before the VM started.
Those warnings do not prove the cause of the reset.

External recorders retain kernel messages, service events, resource samples and workload logs under `~/.local/state/nns-rom/cuttlefish-runtime/` on the operator's machine.
A separate guard samples every two seconds and stops only the tested service.
It requires 12 GiB of available memory and 150 GiB of available disk space.
I/O full-stall means that all active tasks wait for I/O. Its `avg10` field is the ten-second pressure average.
For VM runs, the guard stops the service after five consecutive samples with this value at least 80 percent.
For builds, I/O pressure is advisory. Memory and disk reserves still apply.

Recorder disconnection requests a workload stop. No workload restarts automatically.
The rebuild uses eight-CPU affinity. The next VM launch uses four-CPU affinity instead of relying only on scheduler-dependent CPU quotas.
Enforcing boot completion and NNS runtime assertions remain pending.

Do not use the historical driver below to reproduce this baseline.
It adds NNS and the deferred ARM-bridge experiment before the baseline boot test.

### Earlier integration attempt

The next boot target is user-selected Cuttlefish, not another patched SDK image.
`build-cuttlefish.py` waits for successful Cheetah compilation and image checks
before changing the shared checkout or starting another memory-intensive build.
The user selected the checkout's existing ROM product,
`lineage_cf_phone_x86_64-bp4a-userdebug`, after the initial 64-bit-only AOSP
profile hit mixed-tree product configuration conflicts. That generic profile's
product and BoardConfig patches were restored to their reviewed original hashes.
The selected profile uses `vsoc_x86_64`, including x86 and ARM native-bridge
variants, with a separate `out-cuttlefish` output tree. It inherits the ROM's
SDK, source exclusions and product integration rather than recreating them.
Its existing `TARGET_NO_KERNEL_OVERRIDE := true` skips the ROM kernel-source task
while retaining Cuttlefish's own prebuilt kernel/module packaging.

Hash-guarded product and BoardConfig additions select the production NNS
integration. The lab uses ext4 system images for read-only inspection. The
BoardConfig removes only the absent
`vendor/google_devices/common/proprietary/confirmatioui_hal` namespace export,
after product inheritance has been flattened: `com.google.cf.confirmationui`
already comes from the open-source device project. Missing-dependency,
dex-preopt, product artifact and production neverallow checks remain enabled.
The Cuttlefish radio policy's unconditional `su` socket grant conflicted with the
platform's production neverallow. A hash-guarded patch wraps that grant in
`userdebug_or_eng(...)`, preserving debug behavior while removing the production
permission. Platform neverallows are unchanged.
The ROM-profile compilation gate subsequently passed and was independently
revalidated: init builtin, x86_64 helper, installed RC, policy wiring and production
neverallow binary. That binary has SHA256
`27c065127e1d2468030ff1ebdd0194d3f4cde2c6a3ebd68909015bfffcd410e4`.
Full Cuttlefish images, packaged-kernel verification and enforcing boot remain
pending; the full image build was intentionally stopped on Jeeves in favor of
establishing an unmodified upstream baseline.

The user selected an ARM translation attempt for the ROM's FaceUnlock app rather
than omitting it from the virtual product. Four ARM64-only library definitions
receive hash-guarded `native_bridge_supported: true` additions. The lab sets
`faceunlock.native_bridge` and the app's native-library requirements use Soong
`select()` to request the generated `.native_bridge` modules. Other products keep
the original unsuffixed names; permission files and overlay requirements are
unchanged. The generated Make dependency check has passed this mapping. Artifact
enforcement retains an exact allowance for its ARM64 C++ runtime,
`system/lib64/arm64/libc++.so`. Translator packaging, APK/process ABI selection
and runtime library loading are not yet validated. Successful library generation
alone is not evidence that FaceUnlock runs, especially with its shared system UID.
The user selected open-source Digitalis for translator investigation; candidate
revisions and integration boundaries are in [digitalis-research.md](digitalis-research.md).
No Digitalis build or source-lock replacement has started.

The lab retains the checkout's 6.12 kernel prebuilt, SHA256
`0f6cf8acaf39bc49138677c695d574b3f9f551d0a21a467e560916467f5044f8`,
and checks the packaged kernel against it. No kernel compilation or replacement
is requested. It first builds and verifies init, the x86_64 static helper, policy
and neverallows, then requests the complete default image set and
`cvd-host_package`. Neverallow checks remain enabled for both phases. Source,
integration, kernel and driver hashes are recorded in `cuttlefish-build-inputs.json`.

The target is a generic virtual-device product using the locked platform sources,
not an EvolutionX Cheetah hardware image. Its userdebug variant allows controlled
ADB test fixtures; SELinux must remain enforcing. No runtime policy injection,
KernelSU policy adapter, phone access or flashing is part of this lab. Enforcing
boot and backing-preservation assertions remain pending. The existing source
supports running its QEMU backend without host TAP devices, and Jeeves already
provides writable KVM and vhost-vsock nodes; permanent host networking/group
changes are not planned.

Build-driver regressions are `python3 tests/test-rom-cuttlefish.py` and
`python3 tests/test-rom-build.py`. The read-only raw/sparse image regression also
covers the Cuttlefish output layout. Build the lab from the integration export:

```sh
../environment/bin/nns-rom-build-environment -c 'python3 integrations/rom/build-cuttlefish.py /home/jeeves/Builds/nns-rom'
```

## Native helper regression

From the repository root:

```sh
nix build --builders '' --out-link /tmp/nns-mount-host .#nns-rom-mount-host
nix build --builders '' --out-link /tmp/nns-prepare-host '.#nns-rom-mount-host^tests'
nix shell nixpkgs#util-linux -c python3 tests/test-rom-mount.py \
  /tmp/nns-mount-host/bin/nns-mount /tmp/nns-prepare-host-tests/bin/nns-prepare-backing \
  /tmp/nns-prepare-host-tests/bin/nns-mount-race
```

Uses a disposable chroot inside rootless private user, mount and PID namespaces.
The root is bind-remounted read-only and `/data` is a separate writable tmpfs.
Neither phase sees the host's canonical `/nix` or `/data`. A test-only native
adapter exercises the same preparation function used by init; the mount service
alone refuses absent backing. Covers creation,
repetition, eight concurrent invocations, populated backing preservation,
conflicting/stacked mounts, occupied targets and invalid source/target paths.
A compile-time wrapper replaces the backing pathname after validation to test descriptor pinning.
Each of the four flag mismatches is refused unchanged; matching restrictive
flags are retained. These Linux checks do not test Android SELinux or fscrypt.

## Previous disposable Android experiment

The enforcing SDK results below apply to the earlier helper-owned creation
implementation. This harness has not been updated with the new compiled init
builtin, so it does not validate the current two-phase integration. Source-built
init boot validation is still required; runtime policy injection is insufficient.

Previous harness command (not a current validation command):

```sh
nix run --builders '' .#test-android-mount
```

Requires x86_64 Linux and accessible KVM. Uses private ADB port `15039` and emulator
serial `emulator-5584`; it cannot select a physical phone. The existing
`test-android` private-session experiment remains separate.

The test copies the SDK's GPT disk image, extracts its dynamic system partition,
and adds the empty mountpoint, static helper, entrypoint label and real init
fragment with `debugfs`. It preserves the partition layout and disables AVB
verification only in that disposable image. The SDK encryption seed is exposed
beside the explicit system image so the emulator can copy it into private AVD
storage; the SDK itself remains immutable.

A test-only init fragment runs `ksud post-fs-data` before the production fragment
to load a KSU module's runtime translation of the helper policy. The SDK ramdisk
has no ksud init integration, and its kernel's zygote hook is too late. This
adapter does not supply `/data/nix` or perform the bind; a compiled ROM integration
needs no adapter. The initial adapter-installation boot is not a production cold
boot proof. The SDK ext4 image has `shared_blocks` and remains read-only throughout.

Assertions cover absent backing storage, repeat/concurrent invocation, matching
mount flags, populated-store reboot, preserved directory metadata,
conflicting/stacked mounts, symlink/nondirectory/inaccessible backing rejection,
and preservation of a real fscrypt policy and encrypted contents. Nonempty
unmounted targets and invalid target paths are covered by the native suite,
not this immutable SDK-root fixture. A small test-only syscall fixture remounts
the bind for flag-mismatch assertions, avoiding Android toybox mount's parsing. A test-only init trigger requests an
fscrypt policy **only on a new empty fixture**. A read-only ioctl probe compares
that policy before/after invocation and reboot.

A real zygote instrumentation app must see the global backing inode and fixture
content while retaining its ordinary app UID, SELinux domain and seccomp filter.
The fixture file uses the existing app-readable `shell_data_file` label; the test
adds no broad app store-access grants. The app must not be able to create files
in the root-owned backing directory. Global visibility is not permission to run
arbitrary Nix binaries; keep `nix-enter` for the existing execution model.

These Android assertions have passed with SELinux enforcing. Runtime-injected
policy is not compiled-policy or
neverallow validation, and this emulator intentionally has no SuSFS. Neither ROM
boot safety nor SuSFS app visibility is established by this test.

Logs remain in the printed `nns-android-mount-*` directory. Disposable multi-GB
system/AVD images are removed after shutdown. No phone, daemon, store or OTA is
modified by the test.
