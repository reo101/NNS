#!/usr/bin/env bash
set -euo pipefail
lab=$1
workspace=/home/jeeves/Builds/nns-rom
source=$workspace/source
case "$lab" in "$workspace"/temporary/module-btrfs/storage-vm/*) ;; *) exit 1;; esac
test "$(stat -c '%d:%i' "$workspace/out-cuttlefish")" = "$(stat -c '%d:%i' "$lab/output-cache")"
test ! -w "$source/vendor/lineage/build/target/product/lineage_cf_phone_x86_64.mk"
for name in domain vold; do
    test ! -w "$source/system/sepolicy/private/$name.te"
    cmp "$source/system/sepolicy/private/$name.te" "$lab/source-overrides/platform-$name.te"
done
test -s "$lab/observations/authenticated-init-inputs.json"
cmp "$source/system/core/init/property_service.cpp" "$lab/source-overrides/authenticated-property-service.cpp"
python3 "$lab/export/tests/signing-migration/check-lab-init.py" "$source/system/core/init/property_service.cpp"
test -s "$lab/observations/kernel-module-inputs.json"
cmp "$source/kernel/prebuilts/6.12/x86_64/kernel-6.12" "$lab/artifacts/matched-kernel/kernel"
test ! -w "$source/kernel/prebuilts/6.12/x86_64/kernel-6.12"
sha256sum "$source/system/sepolicy/private/domain.te" "$source/system/sepolicy/private/vold.te" \
    > "$lab/observations/native-policy-input-hashes.txt"
trap 'result=$?; printf "{\"exit_code\":%s}\n" "$result" > "$lab/observations/native-build-exit.json"' EXIT
export OUT_DIR=out-cuttlefish SKIP_KERNEL_BUILD=true SKIP_KERNEL_SYNC=true SELINUX_IGNORE_NEVERALLOWS=false
export GOMEMLIMIT=24GiB GOMAXPROCS=4
export CCACHE_DIR="$lab/compiler-cache" CCACHE_MAXSIZE=10G
cd "$source"
set +u
set +o pipefail
if ! {
    . build/envsetup.sh &&
    lunch lineage_cf_phone_x86_64-bp4a-userdebug &&
    m -j4 SELINUX_IGNORE_NEVERALLOWS=false init_second_stage nns-mount nns-storage nns-storage-fixture NnsStorageApplicationFixture selinux_policy sepolicy_neverallows droid
}; then
    exit 1
fi
set -uo pipefail
product=$workspace/out-cuttlefish/target/product/vsoc_x86_64
test -x "$product/system/bin/nns-storage"
test -x "$product/system/bin/nns-storage-fixture"
grep -Fxq 'ro.nns.storage.fixture=1' "$product/system_ext/etc/build.prop"
grep -Fxq 'ro.nns.mount.owner=init' "$product/system_ext/etc/build.prop"
test -s "$workspace/out-cuttlefish/soong/.intermediates/system/sepolicy/sepolicy_neverallows/android_common/policy"
python3 "$lab/export/tests/rom-storage/check-staged-modules.py" \
    --product "$product" --kernel "$lab/artifacts/matched-kernel" \
    --output "$lab/observations/staged-module-verification.json"
boot_directory=$(mktemp -d "$lab/tmp/boot-kernel.XXXXXX")
python3 "$source/system/tools/mkbootimg/unpack_bootimg.py" --boot_img "$product/boot.img" \
    --out "$boot_directory" > "$lab/observations/exported-boot-header.txt"
cmp "$boot_directory/kernel" "$lab/artifacts/matched-kernel/kernel"
rm -r "$boot_directory"
for image in "$product"/*.img "$product/kernel" "$product/android-info.txt"; do
    cp --remove-destination --reflink=always --dereference --preserve=mode,timestamps "$image" "$lab/runtime-images/"
done
sha256sum "$lab/runtime-images"/*.img > "$lab/observations/runtime-image-hashes.txt"
sha256sum "$lab/runtime-images/boot.img" > "$lab/observations/verified-boot-image.txt"
printf '%s\n' 'PASS: native storage fixture images and enforcing policy compiled with neverallows enabled'
