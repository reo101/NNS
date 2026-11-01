# Optional storage controller candidate

This candidate is not enabled by the default ROM integration. Native policy and
Zig linkage checks pass. Android VM runtime checks are incomplete. Do not deploy it
to the phone.

The Zig storage engine is `module/src/nns-storage.zig`. Its Linux UAPI
(kernel interface) bindings come from `module/src/storage-linux.h`.
Nix builds both the standalone executable and `libnns-storage-controller.a`.
The archive contains the Zig Android controller, not a C shim.
Soong links the archive to platform Bionic for Android property support.
`Android.bp.in` becomes `Android.bp` only in the private lab export.

Init opens `/proc/1/ns/mnt` and passes the namespace descriptor to the controller.
The Zig engine compares its device and inode with the current mount namespace.
The controller rejects a missing or invalid descriptor. It needs neither
`readproc` nor `SYS_PTRACE`. The standalone Linux helper retains its direct
PID-1 check. The `nns_storage` domain mounts and checks the image. It publishes
`sys.nns.storage.ready=1` only after success. The existing `nns_mount` domain
remains bind-only. A stopped service does not establish successful mounting.
The controller rejects `--mode`, because parsing alone cannot establish readiness.

The VM overlay creates device-encrypted fixture storage, starts the storage
controller and binds `/nix` only after readiness. A fixture consumer writes only
when `/nix` and the Btrfs backing have the same identity. No production init
startup action is changed by this directory.

The storage domain can read configuration, access the selected image, use
specified loop ioctls and inspect the mounted Btrfs root. It cannot format,
repair, resize, relabel, copy data, unmount or remount. Kernel loop workers can
read and write only the added image type through these rules.

## Platform policy amendments

`platform-policy.json` records the reviewed source hashes and the two platform
policy amendments. `tests/rom-storage/platform_policy.py` rejects changed source,
ambiguous replacement blocks and existing overlay files. The VM build reads the
amended files through read-only mounts. The ROM checkout remains unchanged.

The mount allowlist adds only `nns_storage`. Additional assertions prohibit this
domain from remounting, unmounting, relabeling filesystems or mounting filesystem
types other than `labeledfs`. SELinux grants apply to labels and operations, not
the Btrfs filesystem name or UUID. The Zig engine validates those values.

The encryption assertion separates key-status queries from key mutation. Only
`vold` and `nns_storage` can query status through data directories. The latter can
use only `nns_storage_file` directories. Key addition, removal and policy
assignment remain forbidden for `nns_storage`, including removal for all users.
These two types are declared in platform policy because it compiles before the
optional `system_ext` policy fragment. The bind-only `nns_mount` domain receives
no new permissions.

The disposable fixture reads encryption policy and creates or reads encrypted
files. It does not query key status. The production controller checks key
availability before it publishes readiness.

Full Cheetah policy compilation passes with the amendments and rejects 13
injected forbidden grants. The Cuttlefish check also includes fixture policy and
rejects 14 grants, including a key-status query from the fixture domain.
Both checks reject a `SYS_PTRACE` grant to the controller.
Neverallow checking remains enabled. The native Cuttlefish image build also
passes its split policy, neverallow and context checks. These are amended-policy
compilation results, not Android boot or CTS results.

## Matched VM kernel and modules

The first VM boot rejected `failover.ko` because its `module_layout` version did
not match the rebuilt Btrfs kernel. `tests/rom-storage/kernel.nix` now builds the
kernel and 142 signed modules together. It includes the virtual-device drivers,
Goldfish drivers, VKMS, V4L2 loopback and virtio-media. Rust, CFI, module-version
checks and the stock automatic module-signing setting remain enabled.

`check-module-versions.py` compares every imported symbol version with the
matched exports. It also requires the expected release and a signing certificate
name. The build enables OpenSSL support in kmod to decode PKCS#7 signatures.
Nixpkgs' default kmod cannot report those signer names.

`prepare-kernel-modules.py` creates private overlays for all prebuilt module
replacements, the kernel and its BTF (kernel type information). It rejects
missing replacements and an active VM. Additional modules go in `system_dlkm`,
which does not load every module automatically. The original checkout remains
unchanged. The VM build preserves the signed module bytes and compares all
staged modules with the verified Nix output before it exports images.
The build also extracts the kernel from `boot.img` and compares it with the matched
kernel. The launcher uses this image without a kernel override. With an override,
Cuttlefish repacks the boot image and can recreate the userdata overlay on restart,
even with `--resume=true`. Force-loading modules or disabling version checks is
not an accepted fix.

## Authenticated VM access

The ROM forces `ro.debuggable=0` even in the selected userdebug product. Its
debug toggle also disables ADB authentication and enables force-debug. The lab
does not use that toggle.

`tests/rom-storage/authenticated-init.json` defines the authorized VM-only init
amendment. It fixes `ro.debuggable=1`, `ro.adb.secure=1`,
`ro.force.debuggable=0` and initial `service.adb.root=0`. Root requires an explicit
request after authentication. The lab installs the ROM's `adb_root` service and
permits its normal root-access setting. It does not set `service.adb.root=1`.
`prepare-authenticated-init.py` checks the source
hash and uses the existing signing-lab authentication validator before it writes
the private overlay. It does not change the source checkout or signing lab.

The product enables the serial console. `enable-console-adb.py` checks VM identity,
enforcement, authentication and boot completion before it enables ADB through
normal Android settings. It does not change authentication or force-debug.
A bounded console unit keeps the host terminal in raw mode to prevent boot output
from echoing back into the guest shell.

The matched images boot with enforcing SELinux. Authenticated ADB and an explicit
root request pass. The fixture copies the image into v2-encrypted F2FS storage and
writes its report under enforcing policy. Direct PID-1 namespace inspection fails
at the kernel's process-inspection check, even with `readproc`. The user selected
the init-provided descriptor instead of a broader capability. Host tests accept
the inherited namespace and reject another namespace, a non-namespace descriptor,
and missing or invalid descriptor values. The native image rebuild includes this
handoff. Enforcing Android tests now pass namespace validation and loop attachment.
Btrfs rejected the first fixture image because its top-level root lacked a SELinux
label. The image generator now labels both roots and checks label persistence
after remount. No access to unlabeled directories is added to the controller.
With the corrected image, the enforcing controller mounts the encrypted backing,
publishes readiness, and permits the bind and current-boot consumer to run.
The fixture write, application execution and unmount/remount checks pass. The
application runs as UID 10303 in `platform_app` and cannot open the private image.
After removal of the redundant kernel override, restart persistence also passes:
the encryption policy and stored marker remain, and the init consumer records
the new boot ID.

The PIN-protected VM also passes a cold boot before first unlock. User 0 remains
`RUNNING_LOCKED`, and the application reports `user_unlocked=false`. The enforcing
controller mounts the image at guest uptime 8.1 seconds. The backing and bind each
have one mount, with matching device and inode values, `nosuid` and `nodev`.
Stored data and the current-boot consumer marker are present.

A separate credential-encrypted marker is readable before shutdown and unreadable
after the locked cold boot. Its v2 policy remains unchanged and differs from the
image's device-encryption policy. This is a credential-storage negative control,
not an Android test of a credential-encrypted backing image. Android tests for
wrong UUID, wrong subvolume, missing image and wrong image label remain pending.
The Linux regression covers identity refusals and unavailable encryption keys.

Cuttlefish puts guest RAM in a regular host file, `internal/qemu.mem`. The VM unit
requires 32 GiB of available host memory and has 24/28 GiB soft/hard limits to reduce
page-cache reclaim. Guest RAM remains 4 GiB. ADB observations have a 120-second
timeout. These host limits do not change the guest kernel or SELinux policy.

`tests/test-rom-storage-controller.py` tests readiness publication and links the
Zig archive with a C linker. `tests/rom-storage/configuration-encryption.nix`
tests configuration discovery with a real fscrypt key present and absent.
The locked-key test reproduced silent directory fallback in the old C helper.
The Zig implementation refuses that fallback.
