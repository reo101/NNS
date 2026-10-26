{
  pkgs,
  size ? "1G",
}:
let
  image = pkgs.testers.runNixOSTest {
    name = "nns-storage-bench-image";
    globalTimeout = 300;
    nodes.machine = { ... }: {
      boot.kernelPackages = pkgs.linuxPackages_6_1;
      boot.supportedFilesystems = [ "btrfs" ];
      environment.systemPackages = [ pkgs.btrfs-progs pkgs.attr pkgs.util-linux ];
      virtualisation.memorySize = 1024;
      virtualisation.diskSize = 4096;
    };
    testScript = ''
      start_all()
      machine.wait_for_unit("multi-user.target")
      machine.succeed("mkdir -p /mnt/bench; truncate -s ${size} /var/nix.btrfs")
      machine.succeed("mkfs.btrfs -f -K -O ^block-group-tree -U 733e8951-cc87-46a3-b746-93b2d225a4fa /var/nix.btrfs")
      machine.succeed("mount -o loop /var/nix.btrfs /mnt/bench; btrfs subvolume create /mnt/bench/nix-root; mkdir /mnt/bench/nix-root/bench; umount /mnt/bench")
      machine.succeed("mount -o loop,subvolid=5 /var/nix.btrfs /mnt/bench")
      for path in ("", "/nix-root", "/nix-root/bench"):
          machine.succeed("setfattr -n security.selinux -v u:object_r:system_data_file:s0 /mnt/bench" + path)
      machine.succeed("chmod 755 /mnt/bench /mnt/bench/nix-root /mnt/bench/nix-root/bench")
      for path in ("", "/nix-root", "/nix-root/bench"):
          print(machine.succeed("getfattr --only-values -n security.selinux /mnt/bench" + path).strip())
      machine.succeed("umount /mnt/bench")
      machine.copy_from_machine("/var/nix.btrfs")
    '';
  };
in
pkgs.runCommand "nns-storage-bench-image" { } ''
  mkdir -p "$out"
  cp ${image}/nix.btrfs "$out/nix.btrfs"
  chmod 600 "$out/nix.btrfs"
  printf 'image=nix.btrfs\nuuid=733e8951-cc87-46a3-b746-93b2d225a4fa\nsubvolume_id=256\n' > "$out/backing.conf"
  chmod 600 "$out/backing.conf"
  cp ${./throughput-probe.zig} "$out/throughput-probe.zig"
''
