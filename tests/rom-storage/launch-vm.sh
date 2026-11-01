#!/usr/bin/env bash
set -euo pipefail
lab=$1
export HOME=$lab/runtime TMPDIR=/tmp/nns-storage-vm-1000
export ANDROID_HOST_OUT=$lab/host-package ADB_VENDOR_KEYS=$lab/authentication/adb
export ADB_USB=0 ADB_MDNS=0
cd "$ANDROID_HOST_OUT"
exec taskset --cpu-list 0-3 ./bin/launch_cvd \
    --system_image_dir="$lab/runtime-images" --resume=true \
    --vm_manager=qemu_cli --guest_enforce_security=true --console=true \
    --enable_tap_devices=false --start_webrtc=false --start_gnss_proxy=false \
    --netsim=false --netsim_bt=false --netsim_uwb=false \
    --enable_host_bluetooth=false --enable_host_uwb=false \
    --extra_bootconfig_args=androidboot.cuttlefish_service_bluetooth_checker=false \
    --report_anonymous_usage_stats=n --gpu_mode=guest_swiftshader \
    --vhost_user_vsock=false --adb_mode=native_vsock --run_adb_connector=false \
    --cpus=4 --memory_mb=4096 --daemon=false
