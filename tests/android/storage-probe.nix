{ pkgs }:
let
  production = pkgs.callPackage ../../nix/storage.nix { };
  probeSource = pkgs.writeText "nns-storage-probe.zig" (builtins.replaceStrings
    [ ''const storage_directory: [:0]const u8 = "/data/nns-storage";'' ''const target_directory: [:0]const u8 = "/data/nix";'' ]
    [ ''const storage_directory: [:0]const u8 = "/data/nns-storage-probe";'' ''const target_directory: [:0]const u8 = "/data/nix-probe";'' ]
    (builtins.readFile ../../module/src/nns-storage.zig));
  helper = production.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      cp ${probeSource} module/src/nns-storage.zig
      mkdir -p tests/module-storage
      cp ${../module-storage/device-probe.zig} tests/module-storage/device-probe.zig
    '';
    buildPhase = builtins.replaceStrings [ "zig build storage " ] [ "zig build storage storage-device-fixture " ] old.buildPhase;
    installPhase = old.installPhase + ''
      install -Dm755 result/bin/nns-storage-device-probe "$out/bin/nns-storage-device-probe"
    '';
  });
  image = pkgs.testers.runNixOSTest {
    name = "nns-storage-probe-image";
    globalTimeout = 120;
    nodes.machine = { ... }: {
      boot.kernelPackages = pkgs.linuxPackages_6_1;
      boot.supportedFilesystems = [ "btrfs" ];
      environment.systemPackages = [ pkgs.btrfs-progs pkgs.util-linux pkgs.attr ];
      virtualisation.memorySize = 768;
      virtualisation.diskSize = 2048;
    };
    testScript = ''
      start_all()
      machine.wait_for_unit("multi-user.target")
      machine.succeed("mkdir -p /var/nns-storage-probe /mnt/nns-storage-probe; truncate -s 256M /var/nns-storage-probe/nix.btrfs")
      machine.succeed("mkfs.btrfs -f -K -O ^block-group-tree -U 733e8951-cc87-46a3-b746-93b2d225a4fa /var/nns-storage-probe/nix.btrfs")
      machine.succeed("mount -o loop /var/nns-storage-probe/nix.btrfs /mnt/nns-storage-probe; btrfs subvolume create /mnt/nns-storage-probe/nix-root")
      machine.succeed("cp ${helper}/bin/nns-storage-device-probe /mnt/nns-storage-probe/nix-root/storage-execution; echo nns-btrfs-isolated-probe > /mnt/nns-storage-probe/nix-root/marker")
      machine.succeed("setfattr -n security.selinux -v u:object_r:system_data_file:s0 /mnt/nns-storage-probe /mnt/nns-storage-probe/nix-root /mnt/nns-storage-probe/nix-root/storage-execution /mnt/nns-storage-probe/nix-root/marker")
      machine.succeed("chmod 755 /mnt/nns-storage-probe /mnt/nns-storage-probe/nix-root /mnt/nns-storage-probe/nix-root/storage-execution; umount /mnt/nns-storage-probe")
      machine.succeed("mount -o loop,ro /var/nns-storage-probe/nix.btrfs /mnt/nns-storage-probe")
      for path in ("", "/nix-root", "/nix-root/storage-execution", "/nix-root/marker"):
          assert machine.succeed("getfattr --only-values -n security.selinux /mnt/nns-storage-probe" + path).strip() == "u:object_r:system_data_file:s0"
      machine.succeed("umount /mnt/nns-storage-probe")
      machine.copy_from_machine("/var/nns-storage-probe/nix.btrfs")
    '';
  };
in pkgs.runCommand "nns-android-storage-probe" { allowedReferences = [ ]; } ''
  mkdir -p "$out"
  cp ${helper}/bin/nns-storage "$out/nns-storage-probe"
  cp ${helper}/bin/nns-storage-supervisor "$out/nns-storage-supervisor"
  cp ${helper}/bin/nns-storage-module-controller "$out/nns-storage-module-controller"
  cp ${helper}/bin/nns-storage-device-probe "$out/nns-storage-device-probe"
  cp ${../module-storage/device-types.rule} "$out/device-types.rule"
  cp ${../module-storage/device-access.rule} "$out/device-access.rule"
  cp ${image}/nix.btrfs "$out/nix.btrfs"
  cp ${probeSource} "$out/helper-source.zig"
  printf 'image=nix.btrfs\nuuid=733e8951-cc87-46a3-b746-93b2d225a4fa\nsubvolume_id=256\n' > "$out/backing.conf"
  chmod 755 "$out/nns-storage-probe" "$out/nns-storage-supervisor" "$out/nns-storage-module-controller" "$out/nns-storage-device-probe"
  (cd "$out"; sha256sum nns-storage-probe nns-storage-supervisor nns-storage-module-controller nns-storage-device-probe device-types.rule device-access.rule nix.btrfs helper-source.zig backing.conf > SHA256SUMS)
''
