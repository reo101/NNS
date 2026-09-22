#!/system/bin/sh
# Stage the root nix daemon's private /etc (used via nix-enter --etc).
#
# nix resolves `trusted-users = ... @group` through ITS OWN NSS: the peer
# uid comes over the socket, gets a passwd name and group memberships from
# the daemon process's /etc. Android's root /etc has neither, and the live
# NoD etc tree is symlink-chained into the store, so materialize writable
# copies here and extend them.
#
# Extra apps become trusted by listing them in /data/nix/etc/nss-trusted,
# one "name:uid:gid" per line: they gain a passwd entry (the uid->name map
# the daemon needs) and membership in nix-trusted (the group @-match needs).
set -eu

etc=/data/nix/var/daemon-etc
nod_etc=/data/data/com.termux.nix/files/usr/etc

# Resolve symlink chains by hand: toybox cp -L does not dereference, and
# store targets (/nix/store/...) only exist on the host as /data/nix/store/...
#
# The NoD etc tree has one hop a naive walk cannot see: entries like group
# point into usr/etc/static, and static is itself a symlink into the store.
# lstat of usr/etc/static/group fails on the host (no /nix), the walk used
# to stop early and keep a dangling link, and appending the nix-trusted line
# through it died with ENOENT - killing the rest of this script under set -e.
# Peel static first, remap /nix on every hop.
static_dst=$nod_etc
if [ -L "$nod_etc/static" ]; then
  st=$(readlink "$nod_etc/static")
  case "$st" in
    /*) ;;
    *) st=$nod_etc/$st ;;
  esac
  case "$st" in /nix/*) st=/data$st ;; esac
  static_dst=$st
fi

resolve() {
  # Echo the host-resolvable target of $1 (file or dir). Always exits 0;
  # empty output means unresolvable.
  path=$1
  hops=0
  while [ "$hops" -lt 12 ]; do
    case "$path" in
      "$nod_etc"/static/*)
        path=$static_dst/${path#"$nod_etc"/static/} ;;
    esac
    if [ -L "$path" ]; then
      target=$(readlink "$path")
      case "$target" in
        /*) path=$target ;;
        *) path=$(dirname "$path")/$target ;;
      esac
      case "$path" in /nix/*) path=/data$path ;; esac
      hops=$((hops + 1))
      continue
    fi
    break
  done
  if [ -e "$path" ]; then
    printf '%s\n' "$path"
  fi
}

# Keep the DIRECTORY inode: sshd sessions and the daemon bind /etc to
# this path, and rm -rf on the dir itself swaps the inode out from under
# those mounts (they pin a deleted, emptied dir -> running sshd suddenly
# has an empty /etc). Wipe children in place; readers re-resolve names.
mkdir -p "$etc"
rm -rf "$etc"/* 2>/dev/null || true

for f in "$nod_etc"/*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  name=${f##*/}
  path=$(resolve "$f")
  if [ -z "$path" ]; then
    # Nothing resolvable on the host: keep the original link, which the
    # daemon's namespace (with /nix mounted) still follows.
    ln -sfn "$f" "$etc/$name"
  elif [ -d "$path" ]; then
    cp -r "$path" "$etc/$name"
  else
    cp "$path" "$etc/$name"
  fi
done

# group/passwd must be REAL files: the nix-trusted line and nss-trusted
# entries are appended below, and appending through a kept symlink targets
# store paths that do not exist as /nix on the host. Re-materialize from
# the resolved chain, or seed the minimal set the daemon's NSS needs.
for crit in group passwd; do
  if [ -f "$etc/$crit" ] && [ ! -L "$etc/$crit" ]; then
    continue
  fi
  rm -f "$etc/$crit"
  src=$(resolve "$nod_etc/$crit")
  if [ -n "$src" ] && [ -f "$src" ] && [ ! -L "$src" ]; then
    cp "$src" "$etc/$crit"
  elif [ "$crit" = group ]; then
    printf '%s\n' 'nix-trusted:x:30000:nix-on-droid' > "$etc/$crit"
  else
    printf '%s\n%s\n' \
      'root:x:0:0::/root:/system/bin/sh' \
      'nix-on-droid:x:10578:10578::/data/data/com.termux.nix/files/home:/system/bin/sh' \
      > "$etc/$crit"
  fi
done

grep -q '^nix-trusted:' "$etc/group" ||
  echo 'nix-trusted:x:30000:nix-on-droid' >> "$etc/group"

if [ -f /data/nix/etc/nss-trusted ]; then
  while IFS=: read -r name uid gid _rest; do
    case "$name" in '' | '#'*) continue ;; esac
    grep -q "^$name:" "$etc/passwd" ||
      echo "$name:x:$uid:$gid:NNS trusted app:/data/data/com.termux.nix/files/home:/system/bin/sh" >> "$etc/passwd"
    members=$(sed -n 's/^nix-trusted:x:[0-9]*://p' "$etc/group")
    case ",$members," in
      *",$name,"*) ;;
      *) sed -i "/^nix-trusted:/ s/$/,${name}/" "$etc/group" ;;
    esac
  done < /data/nix/etc/nss-trusted
fi

chown 0:0 "$etc"
chown -R 0:0 "$etc"/* 2>/dev/null || true
chmod 755 "$etc"
# Files 644, directories 755: a blanket `chmod 644 $etc/*` strips the
# execute bit from dirs like ssl/, and session-uid nix then dies on its
# eager CA load (EACCES traversing /etc/ssl/certs). Session uids read
# this tree; world-readable is the point of staging it.
find "$etc" -type d -exec chmod 755 {} + 2>/dev/null || true
find "$etc" -type f -exec chmod 644 {} + 2>/dev/null || true
# Label per file_contexts (generic /data rule = system_data_file) so the
# ROM's boot `restorecon --recursive /data` walk matches and skips instead
# of paying a denial + printk per path.
chcon -h u:object_r:system_data_file:s0 "$etc" 2>/dev/null || true
chcon -hR u:object_r:system_data_file:s0 "$etc"/* 2>/dev/null || true
