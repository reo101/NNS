#!/bin/sh
# NNS AVF store-share probe: guest init. Mounts the host-side /data/nix/store
# virtiofs share (tag "nix-store"), prints evidence to the VM console, and
# powers the VM off.
mount -t devtmpfs devtmpfs /dev
exec >/dev/console 2>&1

mount -t proc proc /proc
mount -t sysfs sysfs /sys

echo "nns-avf-probe: init running"
echo "--- loading virtiofs modules ---"
for m in virtio_pci_legacy_dev virtio_pci_modern_dev virtio_ring virtio virtio_pci fuse virtiofs; do
    if insmod "/lib/modules/$m.ko"; then
        echo "insmod ok: $m"
    else
        echo "insmod FAILED: $m"
    fi
done
echo "--- /proc/filesystems ---"
cat /proc/filesystems
echo "--- virtio devices ---"
ls /sys/bus/virtio/devices
echo "--- mounting share tag=nix-store ---"
mkdir -p /mnt/store
if mount -t virtiofs nix-store /mnt/store; then
    echo "MOUNT_OK"
    echo "--- /mnt/store (first 30) ---"
    ls /mnt/store | head -n 30
    echo "--- entry count ---"
    ls /mnt/store | wc -l
else
    echo "MOUNT_FAIL"
fi
echo "--- dmesg tail ---"
dmesg | tail -n 40
echo "nns-avf-probe: powering off"
poweroff -f
