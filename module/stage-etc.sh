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

# Resolve each entry's symlink chain by hand: toybox cp -L does not
# dereference, and store targets (/nix/store/...) only exist on the host
# as /data/nix/store/... outside launcher namespaces.
rm -rf "$etc"
mkdir -p "$etc"
for f in "$nod_etc"/*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  name=${f##*/}
  path=$f
  hops=0
  while [ -L "$path" ] && [ "$hops" -lt 10 ]; do
    target=$(readlink "$path")
    case "$target" in
      /*) path=$target ;;
      *) path=$(dirname "$path")/$target ;;
    esac
    hops=$((hops + 1))
  done
  case "$path" in /nix/*) path=/data$path ;; esac
  if [ -d "$path" ]; then
    cp -r "$path" "$etc/$name"
  elif [ -f "$path" ]; then
    cp "$path" "$etc/$name"
  else
    # Nothing resolvable on the host: keep the original link, which the
    # daemon's namespace (with /nix mounted) still follows.
    ln -sfn "$f" "$etc/$name"
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
chmod 644 "$etc"/* 2>/dev/null || true
chcon -h u:object_r:system_file:s0 "$etc" 2>/dev/null || true
chcon -hR u:object_r:system_file:s0 "$etc"/* 2>/dev/null || true
