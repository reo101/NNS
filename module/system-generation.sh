#!/system/bin/sh
# A dangling canonical /nix target is normal outside the launcher namespace.
nns_system_selected() {
  [ -L /data/nix/var/nix/profiles/nns-system ] || return 1
  for directory in /data/nix /data/nix/store /data/nix/var /data/nix/var/nix /data/nix/var/nix/profiles \
      /data/nix/var/nns /data/nix/var/nns/bin /data/nix/var/nns/services; do
    [ -e "$directory" ] || continue
    if [ -L "$directory" ] || [ "$(stat -c %u "$directory")" != 0 ]; then
      echo "nns: system-generation boot requires a root-owned directory: $directory" >&2
      exit 1
    fi
    permissions=$(stat -c %a "$directory")
    # Android mksh does not interpret leading-zero arithmetic as octal.
    case $permissions in
      *[2367][0-7]|*[2367])
        echo "nns: system-generation boot refuses writable administrative directory: $directory" >&2
        exit 1;;
    esac
  done
  if [ "$(stat -c %u /data/nix/var/nix/profiles/nns-system)" != 0 ]; then
    echo 'nns: system generation profile is not root-owned' >&2
    exit 1
  fi
  target=$(readlink /data/nix/var/nix/profiles/nns-system)
  case $target in
    nns-system-*-link)
      case $target in */*|*..*) echo 'nns: invalid generation link' >&2; exit 1;; esac
      if [ "$(stat -c %u "/data/nix/var/nix/profiles/$target")" != 0 ]; then
        echo 'nns: generation link is not root-owned' >&2; exit 1
      fi
      target=$(readlink "/data/nix/var/nix/profiles/$target")
      ;;
  esac
  case $target in
    /nix/store/*)
      object=${target#/nix/store/}
      case $object in ''|*/*|*..*) echo 'nns: invalid store generation' >&2; exit 1;; esac
      ;;
    *) echo 'nns: selected generation is not an immutable store object' >&2; exit 1;;
  esac
  directory=/data/nix/store/$object
  if [ -L "$directory" ] || [ ! -d "$directory" ] || [ "$(stat -c %u "$directory")" != 0 ]; then
    echo 'nns: selected store object is not a root-owned directory' >&2; exit 1
  fi
  permissions=$(stat -c %a "$directory")
  case $permissions in
    *[2367][0-7]|*[2367])
      echo 'nns: selected store object is writable by another identity' >&2; exit 1;;
  esac
  return 0
}
