#!/usr/bin/env bash
#
# NNS (Native Nix Store) - build + adb deploy
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# 1. build the helper (static aarch64, no libc)
( cd "$HERE/src" && zig build-exe nix-enter.zig \
    -target aarch64-linux-musl -O ReleaseSmall -femit-bin=../bin/nix-enter )

# 2. deploy
adb push "$HERE/bin/nix-enter"    /data/adb/modules/nix/bin/nix-enter
adb push "$HERE/module.prop"      /data/adb/modules/nix/module.prop
adb push "$HERE/post-fs-data.sh"  /data/adb/modules/nix/post-fs-data.sh
adb push "$HERE/service.sh"       /data/adb/modules/nix/service.sh
adb push "$HERE/etc/profile"      /data/nix/etc/profile
adb push "$HERE/etc/nix/nix.conf" /data/nix/etc/nix/nix.conf
adb shell 'chmod 755 /data/adb/modules/nix/*.sh /data/adb/modules/nix/bin/nix-enter'

echo "deployed. run:"
echo "  adb shell su -c '/data/adb/modules/nix/bin/nix-enter sh'"
