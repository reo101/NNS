#!/usr/bin/env bash
# Recreate the native Android Emacs configuration from the host checkout.
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_dir=${XDG_CONFIG_HOME:-$HOME/.config}/emacs
serial=${ANDROID_SERIAL:-27211FDH3004Q4}
font=$(fc-match -f '%{file}\n' 'Maple Mono NF CN:style=Regular' | head -n 1)

adb_phone() { command adb -s "$serial" "$@"; }

if [[ $(basename -- "$font") != MapleMono-NF-CN-Regular.ttf || ! -f $font ]]; then
  printf 'Maple Mono NF CN Regular is not installed on this host\n' >&2
  exit 1
fi
for file in config.org early-init.el init.el "$source_dir/nns.el"; do
  if [[ $file = /* ]]; then
    test -f "$file"
  else
    test -f "$config_dir/$file"
  fi
done
adb_phone get-state >/dev/null
if adb_phone shell 'pidof org.gnu.emacs >/dev/null 2>&1'; then
  printf 'Close Android Emacs before provisioning; its buffers will not be stopped automatically\n' >&2
  exit 1
fi
adb_phone shell 'test -d /data/data/org.gnu.emacs/files' || {
  printf 'Install and unlock Android Emacs before provisioning\n' >&2
  exit 1
}

if [[ ! -f $config_dir/config.el || $config_dir/config.org -nt $config_dir/config.el ]]; then
  emacs -Q --batch --eval '(require (quote org))' \
    --eval "(org-babel-tangle-file \"$config_dir/config.org\")"
fi

temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/android-emacs-provision.XXXXXXXX")
remote_dir=
cleanup() {
  if [[ -n $remote_dir ]]; then
    adb_phone shell "rm -rf '$remote_dir'" >/dev/null || true
  fi
  rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

remote_dir=$(adb_phone shell 'umask 077; mktemp -d /data/local/tmp/emacs-provision.XXXXXXXX' | tr -d '\r')
case $remote_dir in
  /data/local/tmp/emacs-provision.*) ;;
  *) printf 'Unexpected Android staging directory: %s\n' "$remote_dir" >&2; exit 1 ;;
esac

tar -C "$config_dir" --exclude='*.elc' -cf "$temporary_dir/config.tar" \
  early-init.el init.el config.org config.el lisp straight/versions
tar -C "$source_dir" --transform='s,^nns\.el$,lisp/nns.el,' \
  -rf "$temporary_dir/config.tar" nns.el
adb_phone push "$temporary_dir/config.tar" "$remote_dir/config.tar" >/dev/null

if ! adb_phone shell 'su -c "test -f /data/data/org.gnu.emacs/files/.emacs.d/straight/repos/straight.el/bootstrap.el && test -f /data/data/org.gnu.emacs/files/.emacs.d/straight/repos/dash.el/dash.el"'; then
  tar -C "$config_dir" -cf "$temporary_dir/repos.tar" straight/repos
  adb_phone push "$temporary_dir/repos.tar" "$remote_dir/repos.tar" >/dev/null
fi

adb_phone push "$font" "$remote_dir/MapleMono-NF-CN-Regular.ttf" >/dev/null
adb_phone push "$source_dir/provision-android-emacs-device.sh" "$remote_dir/provision-device.sh" >/dev/null
adb_phone shell "su -c '/system/bin/sh $remote_dir/provision-device.sh $remote_dir'"
adb_phone shell 'am start -n org.gnu.emacs/.EmacsActivity' >/dev/null

for ((attempt = 0; attempt < 30; attempt++)); do
  if adb_phone shell 'pidof org.gnu.emacs >/dev/null 2>&1 && su -c "test -S /data/nix/var/emacs-server/server && grep -Fq /data/nix/var/emacs-server/server /proc/net/unix"'; then
    printf 'Android Emacs server ready: /data/nix/var/emacs-server/server\n'
    exit 0
  fi
  sleep 2
done
printf 'Android Emacs did not start its server within 60 seconds\n' >&2
exit 1
