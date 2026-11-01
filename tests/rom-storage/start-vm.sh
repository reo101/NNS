#!/usr/bin/env bash
set -euo pipefail
lab=$1
workspace=/home/jeeves/Builds/nns-rom
case "$lab" in "$workspace"/temporary/module-btrfs/storage-vm/*) ;; *) exit 1;; esac
grep -Fxq '{"exit_code":0}' "$lab/observations/native-build-exit.json"
test -s "$lab/observations/staged-module-verification.json"
sha256sum -c "$lab/observations/verified-boot-image.txt"
test -s "$lab/artifacts/matched-kernel/kernel"
test -s "$lab/observations/kernel-module-inputs.json"
test -s "$lab/runtime-images/super.img"
test "$(stat -c '%u:%a' "$lab/runtime")" = "$(id -u):700"
test "$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)" -gt 33554432
if pgrep -u "$(id -u)" -x run_cvd; then exit 1; fi
if systemctl --user is-active --quiet nns-storage-vm.service; then exit 1; fi
if systemctl --user is-active --quiet nns-storage-vm-native-build.service; then exit 1; fi
# A stale console link can point to a PTY reused by another host process.
console=$lab/runtime/cuttlefish/instances/cvd-1/console
if [ -L "$console" ]; then rm -- "$console"; fi
mkdir -p /tmp/nns-storage-vm-1000
chmod 700 /tmp/nns-storage-vm-1000
if ! systemctl --user is-active --quiet nns-storage-vm-adb.service; then
    systemd-run --user --collect --unit=nns-storage-vm-adb \
        --property=MemoryMax=256M --property=CPUQuota=50% --property=RuntimeMaxSec=90min \
        --property="StandardOutput=append:$lab/observations/adb.log" --property=StandardError=inherit \
        "$workspace/runtime-environment/bin/nns-cuttlefish-runtime-environment" \
        "$lab/export/tests/rom-storage/launch-adb.sh" "$lab"
fi
systemd-run --user --collect --unit=nns-storage-vm \
    --property=MemoryHigh=24G --property=MemoryMax=28G --property=CPUQuota=400% \
    --property=Nice=10 --property=TimeoutStopSec=20s --property=RuntimeMaxSec=30min \
    --property="StandardOutput=append:$lab/observations/vm.log" --property=StandardError=inherit \
    "$workspace/runtime-environment/bin/nns-cuttlefish-runtime-environment" \
    "$lab/export/tests/rom-storage/launch-vm.sh" "$lab"
systemd-run --user --collect --unit=nns-storage-vm-console \
    --property=BindsTo=nns-storage-vm.service --property=After=nns-storage-vm.service \
    --property=MemoryMax=128M --property=CPUQuota=10% \
    --property="StandardOutput=append:$lab/observations/console.log" --property=StandardError=inherit \
    "$workspace/environment/bin/nns-rom-build-environment" \
    "$lab/export/tests/rom-storage/launch-console.sh" "$lab"
