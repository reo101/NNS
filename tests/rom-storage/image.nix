{ pkgs }:
let
  execution = pkgs.callPackage ../../nix/native-probes.nix { target = "x86_64-linux-musl"; };
in pkgs.testers.runNixOSTest {
  name = "nns-storage-android-image";
  globalTimeout = 300;
  nodes.machine = { ... }: {
    boot.kernelPackages = pkgs.linuxPackages_6_1;
    boot.supportedFilesystems = [ "btrfs" ];
    environment.systemPackages = [ pkgs.btrfs-progs pkgs.attr ];
    virtualisation.memorySize = 1024;
    virtualisation.diskSize = 2048;
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /mnt/storage; truncate -s 256M /var/nix.btrfs")
    machine.succeed("mkfs.btrfs -f -K -O ^block-group-tree -U 68937ab5-bd17-4fb5-8a7c-6a9a6985e28d /var/nix.btrfs")
    machine.succeed("mount -o loop /var/nix.btrfs /mnt/storage; btrfs subvolume create /mnt/storage/nix-root")
    machine.succeed("cp ${execution}/bin/storage-execution /mnt/storage/nix-root/storage-execution; echo nns-storage-vm-fixture > /mnt/storage/nix-root/marker")
    # Btrfs resolves subvolid through the top-level root during mount.
    machine.succeed("setfattr -n security.selinux -v u:object_r:system_data_file:s0 /mnt/storage")
    machine.succeed("setfattr -n security.selinux -v u:object_r:system_data_file:s0 /mnt/storage/nix-root")
    machine.succeed("setfattr -n security.selinux -v u:object_r:nns_storage_report_file:s0 /mnt/storage/nix-root/marker")
    machine.succeed("setfattr -n security.selinux -v u:object_r:nns_storage_probe_exec:s0 /mnt/storage/nix-root/storage-execution")
    machine.succeed("chmod 755 /mnt/storage /mnt/storage/nix-root /mnt/storage/nix-root/storage-execution; umount /mnt/storage")
    machine.succeed("mount -o loop,ro,subvolid=5 /var/nix.btrfs /mnt/storage")
    for path, label in (("/mnt/storage", "system_data_file"),
                        ("/mnt/storage/nix-root", "system_data_file"),
                        ("/mnt/storage/nix-root/marker", "nns_storage_report_file"),
                        ("/mnt/storage/nix-root/storage-execution", "nns_storage_probe_exec")):
        assert machine.succeed("getfattr --only-values -n security.selinux " + path).strip() == "u:object_r:" + label + ":s0"
    machine.succeed("umount /mnt/storage")
    machine.copy_from_machine("/var/nix.btrfs")
  '';
}
