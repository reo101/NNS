#!/system/bin/sh
# KernelSU blocks init here. Do not wait for another post-fs-data action.
MODDIR=${0%/*}
export PATH=/data/adb/ksu/bin:/system/bin:/system/xbin
storage_mode=$("$MODDIR/bin/nns-storage" --mode) || exit 1
# Btrfs setup can wait for device nodes. Never block init on it here.
if [ "$storage_mode" = btrfs ]; then
  exit 0
fi
. "$MODDIR/prepare-runtime.sh"
