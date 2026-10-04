# The NNS AVF guest: a minimal NixOS for the phone's VirtualizationService.
#
# Shape follows nix-community/nixos-avf, minus the Terminal integration
# (ttyd, storage balloon, graphics): the NNS client boots kernel+initrd
# directly, so there is no bootloader and no ESP. There is no store image
# at all: the root is a small writable ext4 holding only mountpoints, and
# the guest's /nix/store IS the phone's store, mounted read-only over the
# client's nix-store virtiofs share in the initrd (neededForBoot). The
# nixos-init stack (systemd initrd, etc overlay, userborn) initializes
# from the closure that the deploy script pushes into the phone's store -
# the init= parameter selects stage 2 from it and the initrd resolves the
# closure from that parameter. No activation scripts run anywhere.
#
# The phone's nix daemon is reachable through the host's vsock bridge
# (socat VSOCK-LISTEN:15555 on the phone, guest connects to CID 2); the
# socket lands on the canonical path, so NIX_REMOTE=daemon works
# unmodified: the daemon operates on the same directory the virtiofs
# share serves.
{ config, lib, modulesPath, pkgs, ... }:
let
  serialDevice = "ttyS0";
  nixOperationsProof = pkgs.writeShellScript "phone-nix-operations-proof"
    (lib.replaceStrings
      [ "@HELLO@" "@BASH@" "@COREUTILS@" ]
      [ (builtins.unsafeDiscardStringContext pkgs.hello.outPath) "${pkgs.bash}" "${pkgs.coreutils}" ]
      (builtins.readFile ../../tests/avf/nix-operations.sh));
in
{
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];

  # Bashless store-boot stack: no activation scripts, /etc from the etc
  # overlay, users via userborn; the initrd resolves the closure from the
  # init= parameter and runs nixos-init's prepare before switch-root.
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
    "systemd.journald.forward_to_console=1"
  ];
  boot.kernelModules = [
    "virtio_vsock"
    "vhost_vsock"
    "virtiofs"
  ];
  boot.initrd.availableKernelModules = [
    "squashfs"
    "fuse"
    "virtiofs"
  ];

  # The root: a small writable ext4 holding only mountpoints (the payload
  # creates them with debugfs). Everything that matters lives in the
  # phone's store or on tmpfs.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos-root";
    fsType = "ext4";
    neededForBoot = true;
  };

  # The phone's store over the client's nix-store virtiofs share, mounted
  # by the initrd so the closure (and stage 2) is reachable before switch-
  # root. x-initrd.mount keeps the mount out of the initrd cleanup's reach;
  # ro because every write goes through the phone's daemon, which operates
  # on the very same directory host-side.
  fileSystems."/nix/store" = {
    device = "nix-store";
    fsType = "virtiofs";
    neededForBoot = true;
    options = [
      "x-initrd.mount"
      "ro"
    ];
  };

  # AVF supplies the NIC and Android manages its tethering and DHCP server.
  # Boot must still work when a client launches without network support.
  networking.hostName = "nns-guest";
  networking.useDHCP = true;
  networking.useNetworkd = true;
  systemd.network.wait-online.enable = false;
  services.resolved.enable = true;

  services.getty.autologinUser = "root";
  users.users.root.initialHashedPassword = "";

  environment.systemPackages = with pkgs; [
    coreutils
    nix
    socat
  ];

  # Even guest root must use the phone daemon, not open a local store DB.
  environment.variables.NIX_REMOTE = "daemon";
  nix.settings.experimental-features = [ "nix-command" ];

  # Only the phone owns this store; do not start a competing guest daemon.
  systemd.sockets.nix-daemon.enable = false;
  systemd.services.nix-daemon.enable = false;

  systemd.services.phone-nix-daemon-bridge = {
    description = "Phone nix daemon over the AVF vsock bridge";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /nix/var/nix/daemon-socket";
      ExecStart = "${pkgs.socat}/bin/socat UNIX-LISTEN:/nix/var/nix/daemon-socket/socket,fork,unlink-early VSOCK-CONNECT:2:15555";
      Restart = "always";
      RestartSec = 1;
    };
  };

  boot.initrd.systemd.services.nns-boot-filesystem-diagnostic = {
    description = "Verify shared-store symlink reads before switch-root";
    wantedBy = [ "initrd-switch-root.service" ];
    before = [ "initrd-switch-root.service" ];
    unitConfig = {
      DefaultDependencies = false;
      RequiresMountsFor = [ "/sysroot/nix/store" "/sysroot/etc" ];
    };
    path = [ pkgs.coreutils ];
    script = ''
      unit_dir="/sysroot$(readlink /sysroot/etc/systemd/system)"
      echo "nns-guest: absolute store symlink"
      readlink "$unit_dir/-.slice"
      echo "nns-guest: relative store symlink"
      readlink /sysroot${pkgs.bash}/bin/sh
      echo "nns-guest: STORE SYMLINK READS SUCCEEDED"
    '';
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };

  # Self-verification: the client relays the console, so the proof lands
  # in the phone-side output without any guest access.
  systemd.services.phone-daemon-proof = {
    description = "Verify Nix realisation and builds through the phone daemon";
    wantedBy = [ "multi-user.target" ];
    after = [ "phone-nix-daemon-bridge.service" ];
    path = [ pkgs.coreutils pkgs.nix ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = 120;
      ExecStart = pkgs.writeShellScript "phone-daemon-proof" ''
        exec > /dev/console 2>&1
        echo "nns-guest: pinging the phone's daemon over the vsock bridge"
        for attempt in {1..10}; do
          if NIX_REMOTE=daemon ${pkgs.coreutils}/bin/timeout 5 \
            ${pkgs.nix}/bin/nix --extra-experimental-features nix-command store info; then
            echo "nns-guest: PHONE DAEMON REACHABLE"
            exec ${nixOperationsProof}
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
        echo "nns-guest: PHONE DAEMON UNREACHABLE"
        exit 1
      '';
    };
  };

  systemd.services.guest-network-proof = {
    description = "Verify guest DNS and HTTPS independently of the phone daemon";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    path = [ pkgs.curl pkgs.gnugrep pkgs.iproute2 ];
    script = ''
      exec > /dev/console 2>&1
      if curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
        --retry 3 --retry-all-errors --retry-delay 2 \
        --user-agent 'OpenAI File Downloader, XaiImageApiFetch/1.0' \
        https://cache.nixos.org/nix-cache-info | grep -qx 'StoreDir: /nix/store'; then
        ip -brief address
        ip route
        echo 'nns-guest: GUEST DNS AND HTTPS SUCCEEDED'
      else
        ip -brief address
        ip route
        echo 'nns-guest: GUEST DNS OR HTTPS FAILED'
        exit 1
      fi
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  system.stateVersion = "25.05";

  # The payload: kernel+initrd for direct loading by the client, a small
  # empty root image (orphan_file stripped: Android's e2fsck lacks the
  # feature, same fix as nixos-avf) with the mountpoints the boot needs,
  # and the client's vm_config.json. The store is not part of the payload:
  # the deploy script pushes the guest closure into the phone's store,
  # which the initrd mounts over virtiofs.
  system.build.nnsAvfPayload =
    let
      vmConfig = pkgs.writeText "vm_config.json" (builtins.toJSON {
        name = "nns-nixos";
        console_input_device = serialDevice;
        memory_mib = 2048;
        protected = false;
        network = true;
        kernel = "$PAYLOAD_DIR/kernel";
        initrd = "$PAYLOAD_DIR/initrd";
        # init= selects stage 2 from the phone's store; nns.system= is the
        # deploy script's handle for the closure push.
        params = "init=${config.system.build.toplevel}/init+nns.system=${config.system.build.toplevel}+console=tty1+console=${serialDevice}";
        disks = [
          {
            writable = true;
            partitions = [
              {
                label = "nixos-root";
                path = "$PAYLOAD_DIR/root_part";
                writable = true;
              }
            ];
          }
        ];
        sharedPath = [ ];
      });
      # Mountpoint skeleton for the empty root image, plus the two FHS init
      # paths systemd's switch-root probe requires (main.c do_switch_root
      # checks /usr/lib/systemd/systemd and /sbin/init and has no cmdline
      # init= fallback - a store-only root has neither without these).
      # Both point into the phone store, reachable through virtiofs.
      rootDirs = pkgs.writeText "nns-avf-root-dirs.cmds" ''
        mkdir /nix
        mkdir /nix/store
        mkdir /nix/var
        mkdir /etc
        mkdir /run
        mkdir /var
        mkdir /var/log
        mkdir /tmp
        mkdir /proc
        mkdir /sys
        mkdir /dev
        mkdir /usr
        mkdir /usr/lib
        mkdir /usr/lib/systemd
        mkdir /sbin
        symlink /usr/lib/systemd/systemd ${config.systemd.package}/lib/systemd/systemd
        symlink /sbin/init ${config.systemd.package}/lib/systemd/systemd
      '';
    in
    pkgs.runCommand "nns-avf-nixos-payload" { } ''
      mkdir -p $out
      cp ${config.boot.kernelPackages.kernel}/${config.system.boot.loader.kernelFile} $out/kernel
      cp ${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile} $out/initrd
      truncate -s 512M $out/root_part
      ${pkgs.e2fsprogs}/bin/mkfs.ext4 -F -L nixos-root $out/root_part
      # cp inherits the store's 444 mode; debugfs needs write access.
      chmod u+w $out/root_part
      ${pkgs.e2fsprogs}/bin/debugfs -w -f ${rootDirs} $out/root_part
      cp ${vmConfig} $out/vm_config.json
    '';
}
