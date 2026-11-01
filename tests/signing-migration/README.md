# Signing migration lab

These fixtures test a signing change in disposable Cuttlefish images. They are
not a phone migration procedure. Never add the system fixture to a production
product.

## Fixtures

`SigningStateInstrumentation.kt` serves two packages:

| Package | Installation | Signing identity |
| --- | --- | --- |
| `org.nns.signing.system` | Lab system image, shared UID `android.uid.system` | Changes with the platform key |
| `org.nns.signing.application` | Separate APK installed through private ADB | Stays unchanged |

The ordinary fixture uses `android_test_helper_app`. A regular `android_app`
with `installable: false` still enters system staging in this Soong version.
Before booting, make sure that the ordinary fixture is absent from system target
files and that its separate APK contains `classes.dex`.

The `seed` phase creates an AndroidKeyStore AES-GCM key and random markers in
credential-encrypted (CE) and device-encrypted (DE) storage. It saves authenticated
ciphertext for both markers. Existing keys and marker files are not replaced.
The `verify` phase never creates a key. It must decrypt the existing ciphertext
and report the original marker hashes.

Reports also contain the app UID, certificate fingerprint, permission result and
key security level. Grant `POST_NOTIFICATIONS` to the ordinary fixture before
seeding. The system fixture requests `INTERACT_ACROSS_USERS_FULL`.

Run instrumentation with `-e phase seed` or `-e phase verify`. Its component is
`<package>/org.nns.signing.SigningStateInstrumentation`. A successful process
exit alone is not a pass. Require the JSON result's `passed=true` and compare
both packages with `check-state.py`.

## Key exclusion

Before generating keys, install the `signing-keys/` rule in the lab's
`.gitignore`. `generate-lab-keys.sh <lab-directory>` checks this rule before it
creates keys. It refuses existing key files, certificates and symlink paths.
The script generates unencrypted, 30-day RSA lab keys under
`<lab-directory>/signing-keys/lab/`. Keep this directory outside source overrides
and Nix inputs. These keys are not production release keys.

The repository has the same ignore rule. A non-secret file confirmed that an
actual `jj` snapshot excludes the directory before lab key generation.

The lab product supplies its disposable public ADB key through `PRODUCT_ADB_KEYS`.
The public copy also stays in an ignored `signing-keys/` directory. The private
key stays outside source. Normal ADB authentication remains enabled.
In target files, `PRODUCT/etc/security/adb_keys` contains the public key.
`ROOT/adb_keys` is a symlink, not the key contents.

## Tool compatibility

The pinned `LoadInfoDict` accepts an open ZIP file, but its partition mapper
only accepts directories. The standard signer fails before signing any APK.
The lab-only `common.py` override adds ZIP directory detection. Its regression
reproduces the original failure and compares ZIP and directory maps for flat,
nested, priority and empty layouts. It does not change signature checks.
The patch and source hashes stay with the lab observations.

Evolution forces `PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG` in its common product
configuration. The lab uses a private read-only override that clears only this
flag. Keep `ro.debuggable=1` and `ro.adb.secure=1`. Never use
`WITH_ADB_INSECURE` to obtain root. The initial non-debuggable boot was retained;
its root request failed before fixture seeding.

The ROM init also replaces debug properties at runtime. Its persistent debug
switch disables authentication. Do not enable that switch. The user approved a
lab-only init override: keep `ro.debuggable=1`, `ro.adb.secure=1` and
`ro.force.debuggable=0`. Start with `service.adb.root=0`, then request root through
authenticated ADB. `check-lab-init.py <property_service.cpp>` checks this override
before native compilation. These changes do not apply to production source.

The lab also sets `WITH_SU=true` before product inheritance. This installs the
ROM's standard `adb_root` service and debug `su` binary. Enable the ADB-root
setting through `IADBRootService.setEnabled`, using the system UID. This is the
Developer options setting, not a Package Manager database edit. Then request
`adb root` and check the resulting UID and authentication properties.

## Observed results

The Cuttlefish run `20261023T011432Z` used public AOSP keys for its baseline.
It used disposable replacement keys for the new OS images. It did not test the
installed Evolution X certificates on a phone.

| Test | Result |
| --- | --- |
| Same-image reboot | Both UIDs, permissions, CE/DE marker hashes and existing keystore keys survived |
| New keys with the same build identity | Boot failed during network-stack shared-UID reconciliation |
| Restore the control snapshot | Both fixtures and their existing keys passed again |
| New keys with a distinct build identity | New platform certificate reported, with both fixtures' state and existing keys preserved |
| Reboot after the successful migration | New certificate and all fixture state persisted |

NetworkStack and Tethering had matching new APK certificates in the failed
image. Its system fingerprint and incremental version still matched the
baseline. Framework code can reuse stored certificates when the path and
modification time match, unless an upgrade forces certificate collection.

The follow-up used the standard signer's
`--tag_changes=-test-keys,-dev-keys,+release-keys,+nns-signing-migration`.
Android detected an upgrade and collected certificates again. Android init
cleared its package cache through the normal upgrade action. The harness did
not edit Package Manager state or disable signature checks.

Both trials started with identical userdata, metadata and misc hashes. The OS
replacement preserved those partitions and the separate emulator security
state. AVB keys and rollback indexes stayed unchanged. Root ADB required RSA
authentication and rejected an untrusted key. SELinux stayed Enforcing.

Wait for user 0 to reach `RUNNING_UNLOCKED` before instrumentation. The boot
completion property alone can precede CE unlock. The failed early verification
stopped before reading keys or markers. The later verification did not reseed.

Jeeves retains reports, image snapshots and logs under
`/home/jeeves/Builds/nns-rom/temporary/signing-migration/20261023T011432Z/`.
Local reports stay under
`~/.local/state/nns-rom/signing-migration/20261023T011432Z/`.
Private lab keys remain only in the ignored remote key directory.

## Controls and limits

First test a same-image restart. Then test new-key system images against the
same userdata. Keep an inactive snapshot for a recovery control. Do not rewrite
Package Manager state before the unchanged-userdata test. The initial signing
experiment retains the lab AVB keys. It isolates APK signing from a change to
the boot trust root.

`run-fixtures.py` requires a private signing-lab ADB socket and the exact
Cuttlefish identity before any package operation. `replace-os-partitions.py`
accepts only an unshared regular raw disk file inside the lab. It changes a
fixed OS partition list and proves that userdata, metadata and other non-OS
partitions keep their hashes. It is not a block-device flasher.

`python3 tests/test-signing-migration.py` tests report comparisons and key
creation guards without generating keys. Run compilation and Android tests on
Jeeves.

These fixtures do not test authentication-bound keys, physical KeyMint or
StrongBox, PIN recovery, accounts, active APEX updates, or every shared-UID app.
A software key security-level report is not proof about Pixel hardware. The lab
also does not establish acceptance by the phone's bootloader or OTA verifier.
