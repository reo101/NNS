{ lib, pkgs, payload, client, runner, virtiofsd }:
# Deploy the payload and client over adb, then register the guest and
# filesystem backend closures in the phone's store over ssh. The guest
# boots exclusively from that store, exported read-only by virtiofsd.
#
# Usage: nns-avf-deploy-guest <adb-serial> <ssh-host> [ssh-port]
pkgs.writeShellApplication {
  name = "nns-avf-deploy-guest";
  runtimeInputs = with pkgs; [
    android-tools
    coreutils
    gnugrep
    gnused
    nix
    openssh
  ];
  text = ''
    serial=''${1:?adb serial (see adb devices)}
    host=''${2:?ssh host of the phone}
    port=''${3:-8022}

    stage=/data/local/tmp/nns-avf
    root=/data/nix/var/avf

    adb -s "$serial" shell mkdir -p "$stage"
    echo ">> pushing payload (512 MiB writable root image)"
    adb -s "$serial" push ${payload}/kernel ${payload}/initrd ${payload}/vm_config.json "$stage"/
    adb -s "$serial" push ${payload}/root_part "$stage"/root_part
    adb -s "$serial" push ${client}/avf-client.jar "$stage"/avf-client.jar
    adb -s "$serial" push ${runner} "$stage"/run-guest.sh
    adb -s "$serial" push ${pkgs.writeText "nns-avf-virtiofsd-path" "${lib.getExe virtiofsd}\n"} "$stage"/virtiofsd-path

    echo ">> moving into $root (root-only)"
    adb -s "$serial" shell su -c "mkdir -p $root/payload"
    adb -s "$serial" shell su -c "mv $stage/kernel $stage/initrd $stage/root_part $stage/vm_config.json $root/payload/"
    adb -s "$serial" shell su -c "mv $stage/avf-client.jar $stage/run-guest.sh $stage/virtiofsd-path $root/"

    echo ">> pushing the filesystem backend and guest closures into the phone's store"
    nix copy --to "ssh://nix-on-droid@$host:$port" ${virtiofsd}
    # The toplevel is the first nns.system= parameter in the payload's
    # vm_config.json; the phone's ssh sessions talk to its own daemon, so
    # the copy lands in /data/nix/store and is registered there.
    toplevel=$(sed -n 's/.*nns.system=\([^+"]*\).*/\1/p' ${payload}/vm_config.json)
    [ -n "$toplevel" ] || { echo "no nns.system= parameter found" >&2; exit 1; }
    echo "   toplevel: $toplevel"
    nix copy --to "ssh://nix-on-droid@$host:$port" "$toplevel"

    echo ">> done; launch the guest with:"
    echo "   adb -s $serial shell su -c 'sh $root/run-guest.sh $root/payload'"
  '';
}
