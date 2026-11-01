#!/usr/bin/env bash
set -euo pipefail
lab=$1
bubblewrap=$2
workspace=/home/jeeves/Builds/nns-rom
source=$workspace/source
case "$lab" in "$workspace"/temporary/module-btrfs/storage-vm/*) ;; *) exit 1;; esac
test -x "$bubblewrap"
mkdir -p "$lab/tmp" "$lab/compiler-cache"
exec "$bubblewrap" --die-with-parent --unshare-user --uid 1000 --gid 100 --unshare-net \
    --ro-bind / / --dev-bind /dev /dev --proc /proc --tmpfs /tmp \
    --bind "$lab" "$lab" \
    --bind "$lab/output-cache" "$workspace/out-cuttlefish" \
    --ro-bind "$lab/source-overrides/nns-rom" "$source/external/nns-rom" \
    --ro-bind "$lab/source-overrides/product.mk" "$source/vendor/lineage/build/target/product/lineage_cf_phone_x86_64.mk" \
    --ro-bind "$lab/source-overrides/BoardConfig.mk" "$source/device/google/cuttlefish/vsoc_x86_64/BoardConfig.mk" \
    --ro-bind "$lab/source-overrides/platform-domain.te" "$source/system/sepolicy/private/domain.te" \
    --ro-bind "$lab/source-overrides/platform-vold.te" "$source/system/sepolicy/private/vold.te" \
    --ro-bind "$lab/source-overrides/gki-modules" "$source/kernel/prebuilts/6.12/x86_64" \
    --ro-bind "$lab/source-overrides/virtual-device-modules" "$source/kernel/prebuilts/common-modules/virtual-device/6.12/x86-64" \
    --ro-bind "$lab/source-overrides/authenticated-property-service.cpp" "$source/system/core/init/property_service.cpp" \
    --setenv TMPDIR "$lab/tmp" \
    --chdir "$source" /bin/bash "$lab/export/tests/rom-storage/build-lab.sh" "$lab"
