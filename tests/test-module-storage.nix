{ pkgs, storage }:
pkgs.testers.runNixOSTest {
  name = "nns-module-btrfs";
  globalTimeout = 360;
  nodes.machine = { ... }: {
    boot.kernelPackages = pkgs.linuxPackages_6_1;
    boot.kernelParams = [ "loop.max_part=7" ];
    boot.supportedFilesystems = [ "btrfs" "f2fs" ];
    environment.systemPackages = [ storage pkgs.btrfs-progs pkgs.f2fs-tools pkgs.fscryptctl pkgs.util-linux ];
    virtualisation.memorySize = 1024;
    virtualisation.diskSize = 4096;
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    helper = "${storage}/bin/nns-storage"
    uuid = "11111111-2222-3333-4444-555555555555"

    def configuration(image="nix.btrfs", identifier=uuid, subvolume=256):
        machine.succeed("printf '%s\\n' 'image=" + image + "' 'uuid=" + identifier + "' 'subvolume_id=" + str(subvolume) + "' > /data/nns-storage/backing.conf; chmod 600 /data/nns-storage/backing.conf")

    def no_mount():
        machine.fail("mountpoint -q /data/nix")
        machine.succeed("test -z \"$(ls -A /data/nix)\"")

    with subtest("directory mode and strict configuration"):
        machine.succeed("mkdir -p /data/nix")
        assert machine.succeed(helper + " --mode").strip() == "directory"
        machine.succeed(helper + " --check")
        machine.succeed("truncate -s 1G /tmp/android-data.img; mkfs.f2fs -f -O encrypt /tmp/android-data.img; mount -o loop /tmp/android-data.img /data")
        machine.succeed("mkdir -p /data/nix /data/nns-storage /mnt/nns-setup; chmod 700 /data/nns-storage")
        configuration()
        assert machine.succeed(helper + " --mode").strip() == "btrfs"
        machine.fail(helper)
        machine.fail(helper + " --check")
        no_mount()
        for text in ("image=../nix.btrfs", "uuid=invalid", "subvolume_id=0", "unknown=value"):
            configuration()
            machine.succeed("printf '%s\\n' '" + text + "' >> /data/nns-storage/backing.conf")
            machine.fail(helper + " --mode")
        for options in ({"image": "../nix.btrfs"}, {"identifier": "invalid"},
                        {"subvolume": 0}, {"subvolume": 18446744073709551616}):
            configuration(**options)
            machine.fail(helper + " --mode")
        configuration()
        machine.succeed("chmod 644 /data/nns-storage/backing.conf")
        machine.fail(helper + " --mode")
        configuration()
        machine.succeed("chmod 755 /data/nns-storage")
        machine.fail(helper + " --mode")
        machine.succeed("chmod 700 /data/nns-storage; mv /data/nns-storage/backing.conf /data/nns-storage/saved.conf; ln -s saved.conf /data/nns-storage/backing.conf")
        machine.fail(helper + " --mode")
        machine.succeed("rm /data/nns-storage/backing.conf; mv /data/nns-storage/saved.conf /data/nns-storage/backing.conf")

    with subtest("prepared Btrfs subvolume on F2FS"):
        machine.succeed("truncate -s 256M /data/nns-storage/nix.btrfs; chmod 600 /data/nns-storage/nix.btrfs")
        machine.succeed("mkfs.btrfs -f -K -O ^block-group-tree -U " + uuid + " /data/nns-storage/nix.btrfs")
        machine.succeed("mount -o loop /data/nns-storage/nix.btrfs /mnt/nns-setup; btrfs subvolume create /mnt/nns-setup/nix-root; mkdir /mnt/nns-setup/nix-root/store; echo retained > /mnt/nns-setup/nix-root/store/marker; umount /mnt/nns-setup")
        machine.succeed("test \"$(cat /sys/block/loop1/dev)\" = 7:8")
        loops = machine.succeed("losetup -a")
        digest = machine.succeed("sha256sum /data/nns-storage/nix.btrfs")
        machine.fail(helper + " --check")
        assert machine.succeed("sha256sum /data/nns-storage/nix.btrfs") == digest
        assert machine.succeed("losetup -a") == loops
        configuration(identifier="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        machine.fail(helper)
        assert machine.succeed("sha256sum /data/nns-storage/nix.btrfs") == digest
        configuration()
        machine.succeed("touch /data/nix/occupied")
        machine.fail(helper)
        machine.succeed("test -f /data/nix/occupied; rm /data/nix/occupied")
        machine.succeed("ln /data/nns-storage/nix.btrfs /data/nns-storage/image-link")
        machine.fail(helper)
        machine.succeed("rm /data/nns-storage/image-link; mv /data/nns-storage/nix.btrfs /data/nns-storage/saved.btrfs; ln -s saved.btrfs /data/nns-storage/nix.btrfs")
        machine.fail(helper)
        machine.succeed("rm /data/nns-storage/nix.btrfs; mv /data/nns-storage/saved.btrfs /data/nns-storage/nix.btrfs")
        configuration(subvolume=999999)
        machine.fail(helper)
        no_mount()
        machine.wait_until_succeeds("test \"$(losetup -a | wc -l)\" -eq " + str(len(loops.splitlines())))
        configuration()

    with subtest("mount, retention and identity refusal"):
        result, output = machine.execute(helper)
        if result:
            print(machine.succeed("findmnt -M /data/nix; stat -c '%d %i %f' /data/nix /data/nns-storage/nix.btrfs; btrfs subvolume show /data/nix; losetup -l"))
        assert result == 0, output
        machine.succeed(helper + " --check")
        mount_id = machine.succeed("findmnt -rn -M /data/nix -o ID")
        machine.succeed(helper)
        machine.succeed("seq 1 8 | xargs -P8 -I{} " + helper)
        assert machine.succeed("findmnt -rn -M /data/nix -o ID") == mount_id
        machine.succeed("grep -x retained /data/nix/store/marker; echo writable > /data/nix/after-mount; sync")
        machine.fail("unshare -m " + helper + " --check")
        configuration(subvolume=5)
        machine.fail(helper + " --check")
        machine.fail(helper)
        configuration()
        machine.succeed("cp --reflink=never /data/nns-storage/nix.btrfs /data/nns-storage/copy.btrfs; chmod 600 /data/nns-storage/copy.btrfs")
        configuration(image="copy.btrfs")
        machine.fail(helper + " --check")
        machine.fail(helper)
        configuration()
        machine.succeed("mount -o remount,ro /data/nix")
        machine.fail(helper)
        machine.succeed("mount -o remount,rw /data/nix; mount --bind /data/nix /data/nix")
        machine.fail(helper + " --check")
        machine.succeed("umount /data/nix")
        machine.succeed(helper + " --check")

    with subtest("no late backing replacement and persistence"):
        machine.succeed("umount /data/nix; cp " + helper + " /tmp/nns-storage; cp ${pkgs.pkgsStatic.busybox}/bin/busybox /tmp/busybox")
        # Keep the control shell and unmount tool outside the temporarily hidden NixOS store.
        machine.succeed("/tmp/busybox sh -c '/tmp/busybox mount --bind /data/nix /nix || exit 1; /tmp/nns-storage > /tmp/late-backing.log 2>&1; result=$?; /tmp/busybox umount /nix || exit 1; test \"$result\" != 0'")
        machine.succeed("grep -F 'after /nix is bound' /tmp/late-backing.log")
        no_mount()
        machine.succeed(helper)
        machine.succeed("grep -x writable /data/nix/after-mount; grep -x retained /data/nix/store/marker")
        machine.succeed("umount /data/nix")
        machine.wait_until_succeeds("test \"$(losetup -a | wc -l)\" -eq " + str(len(loops.splitlines())))

    with subtest("locked encrypted configuration cannot select directory fallback"):
        machine.succeed("mv /data/nns-storage /data/nns-storage-clear; mkdir /data/nns-storage; chmod 700 /data/nns-storage")
        machine.succeed("head -c 64 /dev/urandom > /tmp/storage-key; fscryptctl add_key /data < /tmp/storage-key > /tmp/storage-key-id; fscryptctl set_policy $(cat /tmp/storage-key-id) /data/nns-storage")
        configuration()
        assert machine.succeed(helper + " --mode").strip() == "btrfs"
        machine.succeed("fscryptctl remove_key $(cat /tmp/storage-key-id) /data; fscryptctl key_status $(cat /tmp/storage-key-id) /data | grep -x Absent")
        machine.fail(helper + " --mode")
        machine.fail(helper + " --check")
        machine.fail(helper)
  '';
}
