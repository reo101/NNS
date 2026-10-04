# The NNS AVF guest: a minimal NixOS for the phone's VirtualizationService.
#
# Shape follows nix-community/nixos-avf, minus the Terminal integration
# (ttyd, storage balloon, graphics): the NNS client boots kernel+initrd
# directly, so there is no bootloader and no ESP; the root image is
# store-only (make-disk-image's LKL path never runs guest binaries, so it
# builds on any host) and the first boot initializes from the closure via
# the nixos-init stack (systemd initrd, etc overlay, userborn) - no
# activation scripts run anywhere.
#
# The phone's nix daemon is reachable through the host's vsock bridge
# (socat VSOCK-LISTEN:15555 on the phone, guest connects to CID 2); the
# socket lands on the canonical path, so NIX_REMOTE=daemon works
# unmodified. The phone's store mounts read-only over /nix/store: the
# daemon does all writes phone-side, and the guest closure must be pushed
# to the phone first (same store paths, so the switch is seamless). If
# the push never happened, this mount fails and the baked store keeps the
# guest alive.
{ config, lib, modulesPath, pkgs, ... }:
let
  serialDevice = "ttyS0";
in
{
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];

  # Bashless store-boot stack: no activation scripts, /etc from the etc
  # overlay, users via userborn; the initrd resolves the closure from the
  # init= parameter and runs nixos-init's prepare-root before switch-root.
  boot.initrd.systemd.enable = true;
  system.nixos-init.enable = true;
  system.etc.overlay.enable = true;
  services.userborn.enable = true;

  # No bootloader: the client passes kernel+initrd to crosvm directly, so
  # there is no ESP and nothing to install; the bare ext4 root is /dev/vda.
  boot.loader.grub.enable = false;
  boot.growPartition = false;

  # Generic kernel: the etc overlay (required by nixos-init) needs >= 6.6,
  # and the avf patches only matter for features this guest does not use.
  boot.kernelPackages = pkgs.linuxPackages_6_6;
  boot.kernelParams = [
    "console=tty1"
    "console=${serialDevice}"
  ];
  boot.kernelModules = [
    "virtio_vsock"
    "vhost_vsock"
    "virtiofs"
  ];
  boot.initrd.availableKernelModules = [ "squashfs" ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # The phone's store over the client's nix-store virtiofs share. Read-
  # only: every write goes through the phone's daemon, which operates on
  # the very same directory host-side.
  fileSystems."/nix/store" = {
    device = "nix-store";
    fsType = "virtiofs";
    options = [ "ro" ];
  };

  # No NIC is configured until the client passes network = true; keep
  # networkd out of the boot path so nothing waits on a missing device.
  networking.hostName = "nns-guest";
  networking.useDHCP = false;
  networking.useNetworkd = false;
  services.resolved.enable = false;

  services.getty.autologinUser = "root";
  users.users.root.initialHashedPassword = "";

  environment.systemPackages = with pkgs; [
    coreutils
    nix
    socat
  ];

  systemd.services.phone-nix-daemon-bridge = {
    description = "Phone nix daemon over the AVF vsock bridge";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /nix/var/nix/daemon/socket";
      ExecStart = "${pkgs.socat}/bin/socat VSOCK-CONNECT:2:15555 UNIX-LISTEN:/nix/var/nix/daemon/socket/socket,fork";
      Restart = "always";
      RestartSec = 1;
    };
  };

  # Self-verification: the client relays the console, so the proof lands
  # in the phone-side output without any guest access.
  systemd.services.phone-daemon-proof = {
    description = "Verify the phone's nix daemon over the vsock bridge";
    wantedBy = [ "multi-user.target" ];
    after = [ "phone-nix-daemon-bridge.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "phone-daemon-proof" ''
        exec > /dev/console 2>&1
        echo "nns-guest: pinging the phone's daemon over the vsock bridge"
        if NIX_REMOTE=daemon ${pkgs.nix}/bin/nix store ping; then
          echo "nns-guest: PHONE DAEMON REACHABLE"
        else
          echo "nns-guest: PHONE DAEMON UNREACHABLE"
        fi
      '';
    };
  };

  system.stateVersion = "25.05";

  # The payload: kernel+initrd for direct loading by the client, the
  # store-only root image (orphan_file stripped: Android's e2fsck lacks
  # the feature, same fix as nixos-avf), and the client's vm_config.json.
  # The client parses params "+"-separated; init= selects stage 2 from
  # the store-only image and nns.system= carries the activation path for
  # anything that needs it before the fstab mounts.
  system.build.nnsAvfPayload =
    let
      diskImage = import "${pkgs.path}/nixos/lib/make-disk-image.nix" {
        inherit lib config pkgs;
        partitionTableType = "none";
        format = "raw";
        onlyNixStore = true;
        installBootLoader = false;
        copyChannel = false;
        additionalSpace = "2G";
        # onlyNixStore defaults the label to "nix-store"; the guest mounts
        # /dev/disk/by-label/nixos.
        label = "nixos";
      };
      vmConfig = pkgs.writeText "vm_config.json" (builtins.toJSON {
        name = "nns-nixos";
        console_input_device = serialDevice;
        memory_mib = 2048;
        protected = false;
        network = true;
        kernel = "$PAYLOAD_DIR/kernel";
        initrd = "$PAYLOAD_DIR/initrd";
        params = "init=${config.system.build.toplevel}/init+nns.system=${config.system.build.toplevel}+console=tty1+console=${serialDevice}";
        disks = [
          {
            writable = true;
            partitions = [
              {
                label = "nixos";
                path = "$PAYLOAD_DIR/root_part";
                writable = true;
              }
            ];
          }
        ];
        sharedPath = [ ];
      });
    in
    pkgs.runCommand "nns-avf-nixos-payload" { } ''
      mkdir -p $out
      cp ${config.boot.kernelPackages.kernel}/${config.system.boot.loader.kernelFile} $out/kernel
      cp ${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile} $out/initrd
      cp ${diskImage}/*.img $out/root_part
      # cp inherits the store's 444 mode; tune2fs needs write access.
      chmod u+w $out/root_part
      ${pkgs.e2fsprogs}/bin/tune2fs -O ^orphan_file $out/root_part
      cp ${vmConfig} $out/vm_config.json
    '';
}
