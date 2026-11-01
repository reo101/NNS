# Cheetah upgrade compatibility

Do not flash the current NNS OTA as a data-preserving update. Its platform and
OTA signing certificates differ from the installed Evolution X certificates.
No authorized signing transition is established.

## Candidate

The inspected package is
`EvolutionX-16.0-20261022-cheetah-11.11-Unofficial.zip`.
Its SHA-256 is
`9bd776bd7c6b00daede147543bdfff5aacc86c61b44f82d0ae56d2404b25df7c`.
The audit reads files extracted from this actual OTA, not loose build outputs.

The candidate predates the `ro.nns.mount.owner=init` interface. Rebuild the ROM
before testing the updated module's ROM-owned mode. The candidate also contains
the upstream kernel, not the separately installed NNS/Btrfs kernel.

## Signing certificates

These values are SHA-256 fingerprints of certificates in DER (binary certificate
encoding). They are not hashes of PEM (text certificate encoding) files or
reported build tags.

| Certificate | Installed Evolution X | Candidate |
| --- | --- | --- |
| Platform, from verified `framework-res.apk` | `40eb6862249866f458337278c8ec891b34b95692cf17ea9ed4cbba47a34135c1` | `c8a2e9bccf597c2fb6dc66bee293fc13f2fc47ec77bc6b2b0d52c11f51192ab8` |
| OTA trust, from `otacerts.zip` | `2444f36668709f807e992d99829e2621d49c3e20ae6eed9c843f6365bd4fb5dc` | `a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc` |

Both platform APK signatures pass APK Signature Scheme v3 verification. That
proves each APK's signature, not permission to replace the installed signer.
The candidate uses public AOSP keys.

The candidate's embedded OTA certificate matches its packaged trust certificate.
The native `check_ota_package_signature` tool accepts the whole package and A/B
payload with that certificate. Verification with the installed OTA certificate
fails. Changing recovery's trust certificate alone does not resolve the separate
platform APK identity change.

A signing lineage (proof authorizing a certificate change) requires authorization
from the previous signer. The installed public certificate cannot provide that
authorization. This project contains no authorized lineage for this transition.

These certificate mismatches do not, by themselves, prove that a wipe is required.
The locked tree's `ReconcilePackageUtils.java` permits changed signatures for
system-image packages and reports `signature changed; retaining data`. Packages
in each shared UID must still have consistent signing identities during boot.
This exception does not authorize the candidate through the installed OTA trust.

The isolated Cuttlefish experiment tested new-key images against unchanged lab
userdata. A same-identity image failed during network-stack shared-UID
reconciliation. NetworkStack and Tethering had matching new certificates, but
the system fingerprint and incremental version matched the baseline.

A follow-up changed the build identity through the standard signer's tag
configuration. Android detected an upgrade and collected certificates again.
Both fixtures retained their UIDs, permissions and marker hashes in
credential-encrypted (CE) and device-encrypted (DE) storage. Their existing
AndroidKeyStore keys still decrypted the original markers. The system fixture
reported the new platform certificate. A later reboot preserved the new signer
and fixture state. Restoring the pre-transition snapshot also passed.

The harness did not edit Package Manager state or disable signature checks.
Android updated its own caches and signing records during normal boot. Both
trials started with identical non-OS partition hashes. Lab AVB keys and rollback
indexes stayed unchanged. Signing keys stay under ignored `signing-keys/`
directories, outside tracked source and Nix inputs.

This experiment changed an AOSP platform key to a disposable lab key. It did not
test the installed Evolution X signer, Pixel hardware keys, accounts, PINs or a
new AVB trust root. See the [lab results](../../tests/signing-migration/README.md).
This is not a phone migration procedure.

Keep phone deployment blocked until a transition is tested and separately
approved. Matching official signing, an authorized lineage, or a clean
installation with tested backup and restore remain other planning routes.
Do not edit the phone's package-manager state as an implicit migration step.

## Security patch levels

Read partition files before comparing patch levels. On this phone, live
`getprop` values differ from the raw files.

| Source | Installed | Candidate |
| --- | --- | --- |
| `/system/build.prop`, system patch level | `2026-08-01` | `2026-09-01` |
| `/vendor/build.prop`, vendor patch level | `2025-12-05` | `2025-12-05` |
| Live system and vendor patch properties | `2026-09-05` | Not boot-tested |

The declared system patch level advances. The vendor patch level does not
change. The live values do not establish a downgrade or the contents of a
partition. No patch date was changed to conceal a compatibility problem.

## Verified Boot and rollback

The candidate and backed-up root vbmeta images use different AVB keys. Their
rollback indexes are `1788220800` and `1782864000`, respectively. These are image
metadata, not the device's stored rollback counters. Device acceptance remains
unverified. Both inspected boot headers are version 4 and encode no OS patch level.

The previous package inspection established internal AVB consistency. It did not
establish device trust, rollback acceptance, hardware boot or safe data reuse.
Do not relock the bootloader based on these checks.

## Evidence

Local evidence is under
`~/.local/state/nns-rom/deployment-audit/20261022T233830Z/`.
`upgrade-compatibility-verified.json` corrects the original report's transposed
OTA certificate fields and mistyped package hash. The original report remains
available for provenance.

Jeeves retains the native signature verification logs under
`/home/jeeves/Builds/nns-rom/temporary/deployment-audit/20261023T041500Z/`.
The corrected JSON is mirrored under
`/home/jeeves/Builds/nns-rom/temporary/deployment-audit/20261022T233830Z/`.
The deployment audit generated no signing keys. Disposable keys were generated
only for the separate ignored lab. Neither activity flashed, rebooted or changed
phone data.
