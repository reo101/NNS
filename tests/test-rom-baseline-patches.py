#!/usr/bin/env python3
"""Check the device-specific baseline patches and source-prefix boundaries."""

import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
patch = root / "integrations/rom/baseline-patches/gs201-overlay-selection.patch"
names = json.loads((root / "integrations/rom/cheetah-overlay-exclusions.json").read_text())
prefixes = [line.split()[1][1:] for line in patch.read_text().splitlines()
            if line.startswith("+    -vendor/pixel-style/rro_overlays/")]

assert set(prefixes) == {f"vendor/pixel-style/rro_overlays/{name}/" for name in names}
for name in names:
    assert any(f"vendor/pixel-style/rro_overlays/{name}/Android.bp".startswith(prefix)
               for prefix in prefixes)
    assert not any(f"device/google/gs201/overlay/{name}/Android.bp".startswith(prefix)
                   for prefix in prefixes)
for name in ("PixelConfigOverlay2019Midyear", "PixelConfigOverlay2018", "GoogleSystemUIOverlay"):
    assert not any(f"vendor/pixel-style/rro_overlays/{name}/Android.bp".startswith(prefix)
                   for prefix in prefixes)
print("PASS: nine generic duplicates excluded; device and distinct generic overlays retained")

profile_patch = (root / "integrations/rom/baseline-patches/cuttlefish-test-profile.patch").read_text()
profile_paths = {line.removeprefix("+++ b/") for line in profile_patch.splitlines()
                 if line.startswith("+++ b/")}
assert profile_paths == {
    "vendor/lineage/build/target/product/lineage_cf_phone_x86_64.mk",
    "vendor/lineage/config/evolution.mk",
    "device/google/cuttlefish/vsoc_x86_64/BoardConfig.mk",
    "device/google/cuttlefish/shared/sepolicy/vendor/telephony/libcuttlefish_rild.te",
}
assert "+ifneq ($(TARGET_PRODUCT),lineage_cf_phone_x86_64)" in profile_patch
excluded_source = "packages/apps/FaceUnlock/Android.bp"
assert f"+PRODUCT_SOURCE_ROOT_DIRS += -{excluded_source}" in profile_patch
assert "packages/apps/FaceUnlock/Android.bp".startswith(excluded_source)
assert not "packages/apps/FaceUnlock/interfaces/biometrics/face/aidl/Android.bp".startswith(excluded_source)
assert "+userdebug_or_eng(`" in profile_patch
for unsupported_override in ("BUILD_BROKEN_MISSING_REQUIRED_MODULES", "SELINUX_IGNORE_NEVERALLOWS", "native_bridge_supported"):
    assert unsupported_override not in profile_patch
print("PASS: virtual profile excludes FaceUnlock without translation or dependency/policy waivers")

audio_patch = (root / "integrations/rom/baseline-patches/audio-effect-factory-lock.patch").read_text()
assert "+++ b/hardware/interfaces/audio/aidl/default/EffectFactory.cpp" in audio_patch
assert [line for line in audio_patch.splitlines()
        if line.startswith("+") and not line.startswith("+++")] == [
    "+    std::lock_guard lg(mMutex);"
]
print("PASS: audio factory correction adds only the required mutex guard")

sandbox_patch = (root / "integrations/rom/baseline-patches/nix-nsjail-store.patch").read_text()
assert [line for line in sandbox_patch.splitlines()
        if line.startswith("+") and "nsjailCmd.WriteString" in line] == [
    '+\t\tnsjailCmd.WriteString(" -R /nix/store")',
    '+\t\tnsjailCmd.WriteString(" -R /etc/ld.so.cache")',
]
job_limit_patch = (root / "integrations/rom/baseline-patches/trusty-build-job-limit.patch").read_text()
assert '+    "--jobs 8 --build-root' in job_limit_patch
print("PASS: nested jail keeps the Nix store read-only and Trusty Make uses eight jobs")

google_patch = (root / "integrations/rom/baseline-patches/cuttlefish-google-split-permission.patch").read_text()
assert "+++ b/vendor/gms/product/blobs/product_blobs.mk" in google_patch
assert [line for line in google_patch.splitlines()
        if line.startswith("+") and not line.startswith("+++")] == [
    "+    features-verizon",
    "+",
    "+ifneq ($(TARGET_PRODUCT),lineage_cf_phone_x86_64)",
    "+PRODUCT_PACKAGES += split-permissions-google",
    "+endif",
]
print("PASS: orphan Google split-permission mapping omitted only for Cuttlefish")

memory_patch = (root / "integrations/rom/baseline-patches/soong-go-memory-limit.patch").read_text()
assert "+++ b/build/soong/ui/build/soong.go" in memory_patch
assert [line for line in memory_patch.splitlines()
        if line.startswith("+") and not line.startswith("+++")] == [
    '+\tif memoryLimit := os.Getenv("GOMEMLIMIT"); memoryLimit != "" {',
    '+\t\tinvocationEnv["GOMEMLIMIT"] = memoryLimit',
    '+\t}',
]
print("PASS: Soong forwards only the Go memory limit into the cleared builder environment")
