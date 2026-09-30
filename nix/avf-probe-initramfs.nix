{ pkgs, lib }:
# Minimal aarch64 initramfs for the AVF store-share probe: statically linked
# busybox as init, mounts the virtiofs share and dumps evidence to the console.
# The archive is intentionally uncompressed: the microdroid kernel ships only
# the LZ4 (legacy) initrd decompressor, so gzip-wrapped cpio is silently
# ignored and the kernel panics on the missing root device.
let
  busybox = pkgs.pkgsCross.aarch64-multiplatform.pkgsStatic.busybox;
  # The probe boots Google's ferrochrome AVF kernel; its virtiofs module chain
  # lives in the EROFS kernel-extras partition inside this archive. Fixed-output
  # fetch: downloaded once, then served from the store/cache.
  ferrochrome = pkgs.fetchurl {
    url = "https://dl.google.com/android/ferrochrome/3600000/aarch64/images.tar.gz";
    hash = "sha256-EGhrNDMI3SxjuJq9O+46IZ4gUmnXtWhDFuHeDVuobrc=";
  };
  kernelModules = pkgs.runCommand "nns-avf-probe-kernel-modules" {
    nativeBuildInputs = [ pkgs.erofs-utils ];
  } ''
    tar -xzf ${ferrochrome} kernel_extras_part
    fsck.erofs --extract=extras kernel_extras_part
    mkdir -p "$out"
    cp extras/lib/modules/*/kernel/drivers/virtio/virtio_pci_legacy_dev.ko \
       extras/lib/modules/*/kernel/drivers/virtio/virtio_pci_modern_dev.ko \
       extras/lib/modules/*/kernel/drivers/virtio/virtio_ring.ko \
       extras/lib/modules/*/kernel/drivers/virtio/virtio.ko \
       extras/lib/modules/*/kernel/drivers/virtio/virtio_pci.ko \
       extras/lib/modules/*/kernel/fs/fuse/fuse.ko \
       extras/lib/modules/*/kernel/fs/fuse/virtiofs.ko \
       "$out/"
  '';
  applets = [
    "sh"
    "mount"
    "umount"
    "ls"
    "cat"
    "mkdir"
    "head"
    "wc"
    "dmesg"
    "tail"
    "poweroff"
    "insmod"
  ];
in
pkgs.runCommand "nns-avf-probe-initramfs"
  {
    nativeBuildInputs = [ pkgs.cpio ];
  }
  ''
    mkdir -p root/dev root/proc root/sys root/mnt/store root/bin
    cp ${busybox}/bin/busybox root/bin/busybox
    ${lib.concatMapStringsSep "\n" (applet: "ln -s busybox root/bin/${applet}") applets}
    cp ${../integrations/avf/probe-init.sh} root/init
    chmod +x root/init
    mkdir -p root/lib/modules
    cp ${kernelModules}/*.ko root/lib/modules/
    (cd root && find . -print0 | cpio --null -o -H newc --quiet) > "$out"
  ''
