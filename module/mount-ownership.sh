#!/system/bin/sh

nns_mount_mode() {
  NNS_MOUNT_MODE=legacy
  mount_owner=$(getprop ro.nns.mount.owner) || {
    echo 'nns: cannot read ROM mount ownership' >&2
    return 1
  }
  case "$mount_owner" in
    '') NNS_MOUNT_MODE=legacy ;;
    init) NNS_MOUNT_MODE=rom ;;
    *) echo 'nns: unsupported ROM mount ownership' >&2; return 1 ;;
  esac
}

nns_check_global_mount() {
  current_namespace=$(readlink /proc/self/ns/mnt 2>/dev/null) || return 1
  init_namespace=$(readlink /proc/1/ns/mnt 2>/dev/null) || return 1
  if [ -z "$current_namespace" ] || [ "$current_namespace" != "$init_namespace" ]; then
    echo 'nns: startup requires the init mount namespace' >&2
    return 1
  fi
  if [ ! -x /system/bin/nns-mount ]; then
    echo 'nns: ROM mount helper is unavailable' >&2
    return 1
  fi
  /system/bin/nns-mount --check
}
