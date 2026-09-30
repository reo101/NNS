#!/system/bin/sh
# Invoked as root from provision-android-emacs.sh after first unlock.
set -eu
umask 077

staging_dir=$1
emacs_home=/data/data/org.gnu.emacs/files
config_dir=$emacs_home/.emacs.d
nod_home=/data/data/com.termux.nix/files/home
sshd_dir=/data/nix/var/sshd
ssh_dir=$emacs_home/.ssh
known_hosts=$ssh_dir/known_hosts
host_key=$sshd_dir/ssh_host_ed25519_key.pub
socket_dir=/data/nix/var/emacs-server
control=/data/nix/var/nns/services/emacs-socket/supervise/control

[ -f "$host_key" ] || { echo 'NoD SSH host key is missing' >&2; exit 1; }
[ -p "$control" ] || { echo 'Emacs socket service is not supervised' >&2; exit 1; }

emacs_uid=$(/system/bin/stat -c %u "$emacs_home")
emacs_gid=$(/system/bin/stat -c %g "$emacs_home")
emacs_context=$(/system/bin/stat -c %C "$emacs_home")
nod_uid=$(/system/bin/stat -c %u "$nod_home")
nod_gid=$(/system/bin/stat -c %g "$nod_home")
nod_context=$(/system/bin/stat -c %C "$nod_home")

# Trust only the key already owned by NoD's root-managed sshd.
read -r host_type host_public_key _ < "$host_key"
[ "$host_type" = ssh-ed25519 ] || { echo 'Unexpected NoD SSH host key type' >&2; exit 1; }
trusted_host="[127.0.0.1]:8022 $host_type $host_public_key"
has_pin=0
if [ -f "$known_hosts" ]; then
  while read -r entry_host entry_type entry_key _; do
    [ "$entry_host" = '[127.0.0.1]:8022' ] || continue
    if [ "$entry_type" != "$host_type" ] || [ "$entry_key" != "$host_public_key" ]; then
      echo 'Pinned NoD SSH host key has changed; refusing to replace it' >&2
      exit 1
    fi
    has_pin=1
  done < "$known_hosts"
fi

/system/bin/mkdir -p "$config_dir" "$config_dir/straight" "$ssh_dir" "$emacs_home/fonts" "$nod_home/.ssh"
/system/bin/chown "$emacs_uid:$emacs_gid" "$config_dir" "$config_dir/straight" "$ssh_dir" "$emacs_home/fonts"
/system/bin/chcon "$emacs_context" "$config_dir" "$config_dir/straight" "$ssh_dir" "$emacs_home/fonts"
/system/bin/chmod 700 "$config_dir" "$ssh_dir"
/system/bin/chmod 755 "$emacs_home/fonts"

/system/bin/tar -oxf "$staging_dir/config.tar" -C "$config_dir"
/system/bin/chown "$emacs_uid:$emacs_gid" "$config_dir" "$config_dir/lisp" "$config_dir/straight" "$config_dir/straight/versions"
/system/bin/chown -R "$emacs_uid:$emacs_gid" "$config_dir/lisp" "$config_dir/straight/versions"
/system/bin/chcon -hR "$emacs_context" "$config_dir/lisp" "$config_dir/straight/versions"
for file in early-init.el init.el config.org config.el; do
  /system/bin/chown "$emacs_uid:$emacs_gid" "$config_dir/$file"
  /system/bin/chcon "$emacs_context" "$config_dir/$file"
done

if [ -f "$staging_dir/repos.tar" ]; then
  /system/bin/tar -oxf "$staging_dir/repos.tar" -C "$config_dir"
  /system/bin/chown "$emacs_uid:$emacs_gid" "$config_dir/straight"
  /system/bin/chown -R "$emacs_uid:$emacs_gid" "$config_dir/straight/repos"
  /system/bin/chcon -hR "$emacs_context" "$config_dir/straight/repos"
fi

/system/bin/cp "$staging_dir/MapleMono-NF-CN-Regular.ttf" "$emacs_home/fonts/MapleMono-NF-CN-Regular.ttf"
/system/bin/chown "$emacs_uid:$emacs_gid" "$emacs_home/fonts/MapleMono-NF-CN-Regular.ttf"
/system/bin/chcon "$emacs_context" "$emacs_home/fonts/MapleMono-NF-CN-Regular.ttf"
/system/bin/chmod 644 "$emacs_home/fonts/MapleMono-NF-CN-Regular.ttf"

if [ ! -f "$ssh_dir/id_ed25519" ]; then
  /system/bin/env -u LD_PRELOAD /product/bin/ssh-keygen -q -t ed25519 -N '' \
    -C android-emacs-nod -f "$ssh_dir/id_ed25519" </dev/null
fi
/system/bin/chown "$emacs_uid:$emacs_gid" "$ssh_dir/id_ed25519"
/system/bin/chmod 600 "$ssh_dir/id_ed25519"
public_key=$(/system/bin/env -u LD_PRELOAD /product/bin/ssh-keygen -y -f "$ssh_dir/id_ed25519")
key_type=${public_key%% *}
key_data=${public_key#* }
key_data=${key_data%% *}
[ "$key_type" = ssh-ed25519 ] || { echo 'Unexpected Android Emacs SSH key type' >&2; exit 1; }
/system/bin/printf '%s %s android-emacs-nod\n' "$key_type" "$key_data" > "$ssh_dir/id_ed25519.pub"
/system/bin/chown "$emacs_uid:$emacs_gid" "$ssh_dir/id_ed25519.pub"
/system/bin/chcon "$emacs_context" "$ssh_dir/id_ed25519" "$ssh_dir/id_ed25519.pub"
/system/bin/chmod 644 "$ssh_dir/id_ed25519.pub"

if [ "$has_pin" = 0 ]; then
  /system/bin/printf '%s\n' "$trusted_host" >> "$known_hosts"
fi
/system/bin/chown "$emacs_uid:$emacs_gid" "$known_hosts"
/system/bin/chcon "$emacs_context" "$known_hosts"
/system/bin/chmod 600 "$known_hosts"

/system/bin/chown "$nod_uid:$nod_gid" "$nod_home/.ssh"
/system/bin/chcon "$nod_context" "$nod_home/.ssh"
/system/bin/chmod 700 "$nod_home/.ssh"
authorized_keys=$nod_home/.ssh/authorized_keys
[ -e "$authorized_keys" ] || : > "$authorized_keys"
managed_key="from=\"127.0.0.1\",restrict,pty $key_type $key_data android-emacs-nod"
if ! /system/bin/grep -Fxq "$managed_key" "$authorized_keys"; then
  next_keys=$(/system/bin/mktemp "$nod_home/.ssh/authorized_keys.XXXXXXXX")
  /system/bin/sed '/ android-emacs-nod$/d' "$authorized_keys" > "$next_keys"
  /system/bin/printf '%s\n' "$managed_key" >> "$next_keys"
  /system/bin/chown "$nod_uid:$nod_gid" "$next_keys"
  /system/bin/chcon "$nod_context" "$next_keys"
  /system/bin/chmod 600 "$next_keys"
  /system/bin/mv -f "$next_keys" "$authorized_keys"
fi
/system/bin/chown "$nod_uid:$nod_gid" "$authorized_keys"
/system/bin/chcon "$nod_context" "$authorized_keys"
/system/bin/chmod 600 "$authorized_keys"
/system/bin/cp "$authorized_keys" "$sshd_dir/authorized_keys"
/system/bin/chown "$nod_uid:$nod_gid" "$sshd_dir/authorized_keys"
/system/bin/chcon u:object_r:system_data_file:s0 "$sshd_dir/authorized_keys"
/system/bin/chmod 600 "$sshd_dir/authorized_keys"

# Reuse the existing unlock-gated service, including its UID and label checks.
/system/bin/printf t > "$control"
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
  if [ "$(/system/bin/stat -c '%u:%g:%a:%C' "$socket_dir")" = "$emacs_uid:$nod_gid:2710:$emacs_context" ]; then
    exit 0
  fi
  /system/bin/sleep 1
done
echo 'Emacs socket service did not provision its directory' >&2
exit 1
