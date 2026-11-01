#!/usr/bin/env bash
set -euo pipefail
lab=$1
export HOME=$lab/runtime ADB_VENDOR_KEYS=$lab/authentication/adb
export ADB_USB=0 ADB_MDNS=0
export ADB_SERVER_SOCKET=localfilesystem:/tmp/nns-storage-vm-1000/adb.sock
exec "$lab/host-package/bin/adb" -L "$ADB_SERVER_SOCKET" nodaemon server
