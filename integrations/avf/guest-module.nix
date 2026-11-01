# The NNS AVF guest: a minimal NixOS for the phone's VirtualizationService.
#
# Shape follows nix-community/nixos-avf, minus the Terminal integration
# (ttyd, storage balloon, graphics): the NNS client boots kernel+initrd
# directly, so there is no bootloader and no ESP. The root is a small
# writable ext4 holding only mountpoints. The guest's /nix/store starts as
# the phone's store, mounted read-only over the client's nix-store virtiofs
# share in the initrd (neededForBoot), so the nixos-init stack (systemd
# initrd, etc overlay, userborn) can start from the closure the deploy
# script pushes into the phone's store. No activation scripts run.
#
# At boot the guest formats a second writable partition (nix-upper),
# copies the running system closure and the phone database into it, and
# bind-mounts it over /nix/store and /nix/var. The guest nix-daemon then
# builds into that store with the Nix sandbox and nixbld users. The phone
# store is the read-only source; the build partition is the writable store.
#
# The phone's nix daemon is reachable through the host's vsock bridge
# (socat VSOCK-LISTEN:15555 on the phone, guest connects to CID 2) at
# /run/nns-phone-daemon/socket. `nns-publish` copies finished outputs back
# into the phone store through that bridge. The phone side proxies to the
# supervised daemon socket, so the daemon sees a root client and accepts
# unsigned guest outputs; it is a publication path, not the build path.
{ config, lib, modulesPath, pkgs, ... }:
let
  serialDevice = "ttyS0";
  nixOperationsProof = pkgs.writeShellScript "phone-nix-operations-proof"
    (lib.replaceStrings
      [ "@HELLO@" "@BASH@" "@COREUTILS@" ]
      [ (builtins.unsafeDiscardStringContext pkgs.hello.outPath) "${pkgs.bash}" "${pkgs.coreutils}" ]
      (builtins.readFile ../../tests/avf/nix-operations.sh));
  publish = pkgs.writeShellApplication {
    name = "nns-publish";
    runtimeInputs = [ config.nix.package ];
    text = ''
      socket=/run/nns-phone-daemon/socket
      if [ ! -S "$socket" ]; then
        echo "phone daemon bridge is not available at $socket" >&2
        exit 1
      fi
      export NIX_REMOTE=
      export NIX_DAEMON_SOCKET_PATH="$socket"
      exec nix copy --no-check-sigs --to daemon "$@"
    '';
  };
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
  documentation.enable = false;

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
    "overlay"
    "virtio_vsock"
    "vhost_vsock"
    "virtiofs"
  ];
  boot.kernel.sysctl."fs.file-max" = 1048576;
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

  # The phone's /data/nix (store and var) over the client's nix-store
  # virtiofs share, mounted by the initrd so the closure (and stage 2) is
  # reachable before switch-root. It is the read-only lower layer for the
  # guest store overlays; the build partition is the upper layer. ro
  # because every phone-side write goes through the phone daemon.
  fileSystems."/nix" = {
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

  environment.systemPackages = [
    pkgs.coreutils
    pkgs.e2fsprogs
    pkgs.socat
    pkgs.util-linux
    publish
  ];

  # Guest clients use the guest daemon. The phone bridge is a separate
  # socket used only for publication.
  environment.variables.NIX_REMOTE = "daemon";
  nix.package = pkgs.nixVersions.latest;
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    sandbox = true;
    build-users-group = "nixbld";
    require-sigs = false;
    builders = lib.mkForce "";
    max-jobs = 2;
    keep-outputs = true;
    keep-derivations = true;
  };
  nix.nrBuildUsers = 8;

  systemd.services.phone-nix-daemon-bridge = {
    description = "Phone nix daemon over the AVF vsock bridge";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStartPre = "${lib.getExe' pkgs.coreutils "mkdir"} -p /run/nns-phone-daemon";
      ExecStart = "${lib.getExe pkgs.socat} UNIX-LISTEN:/run/nns-phone-daemon/socket,fork,unlink-early VSOCK-CONNECT:2:15555";
      Restart = "always";
      RestartSec = 1;
    };
  };

  systemd.services.nns-build-store = {
    description = "Prepare the writable guest store";
    wantedBy = [ "multi-user.target" ];
    before = [ "multi-user.target" "nix-daemon.service" ];
    after = [ "local-fs.target" "phone-nix-daemon-bridge.service" ];
    requires = [ "phone-nix-daemon-bridge.service" ];
    unitConfig.RequiresMountsFor = [ "/nix" ];
    path = [ pkgs.coreutils pkgs.e2fsprogs pkgs.findutils pkgs.gnugrep pkgs.util-linux config.nix.package ];
    script = ''
      set -euo pipefail
      trap 'echo "nns-guest: GUEST STORE FAILED" >&2' ERR
      device=/dev/disk/by-partlabel/nix-upper
      for attempt in $(seq 1 50); do
        [ -b "$device" ] && break
        if [ -b /dev/vda2 ]; then device=/dev/vda2; break; fi
        sleep 0.2
      done
      [ -b "$device" ] || { echo 'nns-guest: BUILD PARTITION MISSING' >&2; exit 1; }
      mkdir -p /build
      if [ "$(blkid -s TYPE -o value "$device" 2>/dev/null)" != "ext4" ]; then
        mkfs.ext4 -F -L nix-upper "$device"
      fi
      mountpoint -q /build || mount "$device" /build
      mkdir -p /build/nix/store /build/nix/var/nix/db
      cp /nix/var/avf/db.sqlite /build/nix/var/nix/db/db.sqlite
      socket=/run/nns-phone-daemon/socket
      for attempt in $(seq 1 100); do
        [ -S "$socket" ] && break
        sleep 0.2
      done
      [ -S "$socket" ] || { echo 'nns-guest: PHONE STORE UNREACHABLE' >&2; exit 1; }
      system=$(readlink -f /run/current-system)
      nix path-info --store 'local?store=/nix/store&root=/build' --recursive "$system" \
        | xargs -r -n 50 \
          cp -a -t /build/nix/store --
      mkdir -p /build/nix/var/nix/gcroots /build/nix/var/nix/daemon-socket
      rm -f /build/nix/var/nix/daemon-socket/socket
      ln -sfn "$system" /build/nix/var/nix/gcroots/current-system
      mount --bind /build/nix/store /nix/store || { echo 'nns-guest: STORE BIND FAILED' >&2; exit 1; }
      findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /nix/store || true
      mount --bind /build/nix/var /nix/var || { echo 'nns-guest: VAR BIND FAILED' >&2; exit 1; }
      echo 'nns-guest: GUEST STORE READY'
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = 900;
      LimitNOFILE = 262144;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };

  systemd.sockets.nix-daemon.enable = lib.mkForce false;
  systemd.services.nix-daemon = {
    enable = lib.mkForce true;
    wantedBy = lib.mkForce [ "multi-user.target" ];
    after = [ "nns-build-store.service" ];
    requires = [ "nns-build-store.service" ];
    serviceConfig = {
      ExecStart = lib.mkForce [ "" "${config.nix.package}/bin/nix-daemon --daemon" ];
      Sockets = lib.mkForce [ ];
    };
  };

  boot.initrd.systemd.services.nns-boot-filesystem-diagnostic = {
    description = "Verify shared-store symlink reads before switch-root";
    wantedBy = [ "initrd-switch-root.service" ];
    before = [ "initrd-switch-root.service" ];
    unitConfig = {
      DefaultDependencies = false;
      RequiresMountsFor = [ "/sysroot/nix" "/sysroot/etc" ];
    };
    path = [ pkgs.coreutils ];
    script = ''
      unit_dir="/sysroot$(readlink /sysroot/etc/systemd/system)"
      echo "nns-guest: absolute store symlink"
      readlink "$unit_dir/-.slice"
      echo "nns-guest: relative store symlink"
      readlink /sysroot${lib.getExe' pkgs.bash "sh"}
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
  systemd.services.guest-build-proof = {
    description = "Verify a sandboxed guest build and phone publication";
    wantedBy = [ "multi-user.target" ];
    after = [ "nns-build-store.service" "phone-nix-daemon-bridge.service" "network.target" ];
    path = [ pkgs.coreutils config.nix.package pkgs.util-linux ];
    script = ''
      exec > /dev/console 2>&1
      exec ${nixOperationsProof}
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = 900;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };

  systemd.services.nix-daemon-debug = {
    description = "Dump the Nix daemon journal after the proof";
    wantedBy = [ "multi-user.target" ];
    after = [ "guest-build-proof.service" "multi-user.target" ];
    path = [ pkgs.systemd pkgs.coreutils pkgs.util-linux ];
    script = ''
      exec > /dev/console 2>&1
      echo "nns-guest: SYSTEM STATE $(systemctl is-system-running 2>/dev/null || true)"
      echo "nns-guest: MULTI USER $(systemctl show -p ActiveState --value multi-user.target)"
      systemctl status nix-daemon.service --no-pager || true
      journalctl -u nix-daemon.service -b --no-pager | tail -120 || true
      findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /nix || true
      findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /nix/store || true
      findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /build || true
      grep -E ' /nix| /build' /proc/self/mountinfo || true
      ls -la /nix/var/nix/daemon-socket /build/nix/var/nix/db || true
      pid=$(systemctl show -p MainPID --value nix-daemon.service)
      echo "nns-guest: daemon pid=$pid"
      cat "/proc/$pid/wchan" || true
      echo
      grep -E ' /nix| /build' "/proc/$pid/mountinfo" || true
      grep -E 'daemon-socket' /proc/net/unix || true
      ls -l "/proc/$pid/fd" || true
      ss -xlp 2>/dev/null | grep -i nix || true
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
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
        'https://cache.nixos.org/nix-cache-info' | grep -qx 'StoreDir: /nix/store'; then
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

  system.stateVersion = "26.11";

  # The payload: kernel+initrd for direct loading by the client, a small
  # empty root image (orphan_file stripped: Android's e2fsck lacks the
  # feature, same fix as nixos-avf) with the mountpoints the boot needs,
  # and the client's vm_config.json. The writable build partition is a
  # sparse file the deploy script creates on the phone; the guest formats
  # it on first boot. The store is not part of the payload: the guest
  # seeds it from the phone store at boot.
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
              {
                label = "nix-upper";
                path = "$PAYLOAD_DIR/build_part";
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
      rootDirs = pkgs.writeText "nns-avf-root-dirs.cmds" /* bash */ ''
        # mkdir /nix
        # mkdir /nix/store
        # mkdir /nix/var
        # mkdir /build
        # mkdir /etc
        # mkdir /run
        # mkdir /var
        # mkdir /var/log
        # mkdir /tmp
        # mkdir /proc
        # mkdir /sys
        # mkdir /dev
        # mkdir /usr
        # mkdir /usr/lib
        # mkdir /usr/lib/systemd
        # mkdir /sbin

        ${lib.pipe [
          "/nix"
          "/nix/store"
          "/nix/var"
          "/build"
          "/etc"
          "/run"
          "/var"
          "/var/log"
          "/tmp"
          "/proc"
          "/sys"
          "/dev"
          "/usr"
          "/usr/lib"
          "/usr/lib/systemd"
          "/sbin"
        ] [
          (lib.toposort lib.hasPrefix)
          (lib.getAttr "result")
          (lib.map (p: /* bash */ "mkdir ${lib.escapeShellArg p}"))
          (lib.concatStringsSep "\n")
        ]}

        symlink /usr/lib/systemd/systemd ${config.systemd.package}/lib/systemd/systemd
        symlink /sbin/init ${config.systemd.package}/lib/systemd/systemd
      '';
    in
    pkgs.runCommand "nns-avf-nixos-payload" { } ''
      mkdir -p $out
      cp ${config.boot.kernelPackages.kernel}/${config.system.boot.loader.kernelFile} $out/kernel
      cp ${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile} $out/initrd
      truncate -s 512M $out/root_part
      ${lib.getExe' pkgs.e2fsprogs "mkfs.ext4"} -F -L nixos-root $out/root_part
      # cp inherits the store's 444 mode; debugfs needs write access.
      chmod u+w $out/root_part
      ${lib.getExe' pkgs.e2fsprogs "debugfs"} -w -f ${rootDirs} $out/root_part
      cp ${vmConfig} $out/vm_config.json
    '';
}
