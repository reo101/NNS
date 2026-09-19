#!/system/bin/sh
#
# NNS - service stage: just a health check / convenience
#
LOG=/data/local/tmp/nix-service.log
exec > $LOG 2>&1
set -x

[ -d /data/nix/store ] && echo "nix store present"
ls /data/adb/modules/nix/bin/nix-enter && echo "nix-enter helper present"
echo "usage: su -c '/data/adb/modules/nix/bin/nix-enter <command>'"
