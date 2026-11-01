{ pkgs }:
let storage = pkgs.callPackage ../../nix/storage.nix { target = "x86_64-linux-musl"; };
in pkgs.testers.runNixOSTest {
  name = "nns-storage-configuration-encryption";
  globalTimeout = 360;
  nodes.machine = { ... }: {
    boot.kernelPackages = pkgs.linuxPackages_6_1;
    boot.supportedFilesystems = [ "f2fs" ];
    environment.systemPackages = [ storage pkgs.fscryptctl pkgs.f2fs-tools ];
    virtualisation.memorySize = 1024;
    virtualisation.diskSize = 2048;
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    helper = "${storage}/bin/nns-storage"
    machine.succeed("mkdir -p /data; truncate -s 512M /tmp/data.img; mkfs.f2fs -f -O encrypt /tmp/data.img; mount -o loop /tmp/data.img /data")
    machine.succeed("mkdir /data/nns-storage; chmod 700 /data/nns-storage; head -c 64 /dev/urandom > /tmp/key; fscryptctl add_key /data < /tmp/key > /tmp/key-id; fscryptctl set_policy $(cat /tmp/key-id) /data/nns-storage")
    assert machine.succeed(helper + " --mode").strip() == "directory"
    machine.succeed("printf 'image=nix.btrfs\\nuuid=68937ab5-bd17-4fb5-8a7c-6a9a6985e28d\\nsubvolume_id=256\\n' > /data/nns-storage/backing.conf; chmod 600 /data/nns-storage/backing.conf")
    assert machine.succeed(helper + " --mode").strip() == "btrfs"
    digest = machine.succeed("sha256sum /data/nns-storage/backing.conf")
    machine.succeed("fscryptctl remove_key $(cat /tmp/key-id) /data; fscryptctl key_status $(cat /tmp/key-id) /data | grep -x Absent")
    machine.fail(helper + " --mode")
    machine.fail(helper + " --check")
    machine.fail(helper)
    machine.succeed("fscryptctl add_key /data < /tmp/key")
    assert machine.succeed(helper + " --mode").strip() == "btrfs"
    assert machine.succeed("sha256sum /data/nns-storage/backing.conf") == digest
  '';
}
