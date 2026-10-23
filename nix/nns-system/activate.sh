#!/bin/sh
set -eu

fail() { printf 'nns activation: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || fail 'activation requires root'
[ "$#" -eq 2 ] || fail 'usage: activate.sh GENERATION switch|boot'
generation=$1
case $2 in switch|boot) ;; *) fail 'mode must be switch or boot' ;; esac
[ -d "$generation/system-profile/bin" ] && [ -d "$generation/etc" ] || fail 'invalid generation'
sp=$generation/system-profile
state=${NNS_STATE_DIRECTORY:-/data/nix/var/nns}
etc_root=${NNS_ETC_DIRECTORY:-/data/nix/var/daemon-etc}
profiles=${NNS_PROFILE_DIRECTORY:-/nix/var/nix/profiles}
nix_conf=${NNS_NIX_CONF_DIRECTORY:-/data/nix/etc/nix}
launcher=${NNS_LAUNCHER:-/data/nix/bin/nix-enter}
# The entry point supplies this immutable PATH, never an application profile.
export PATH="$sp/bin:/system/bin:/system/xbin"
for tool in sh env tr rmdir nix nix-env sleep runsvdir sv flock install mv mkdir mktemp cp chmod chown stat readlink ln rm find grep cut cat nohup; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing system tool: $tool"
done
valid_name() { case $1 in [A-Za-z0-9]*) case $1 in *[!A-Za-z0-9_-]*) return 1;; *) return 0;; esac;; *) return 1;; esac; }
check_directory() {
    case $1 in /*) ;; *) fail "directory is not absolute: $1";; esac
    case $1 in /|/etc|/var|/system) fail "refusing Android system directory: $1";; esac
    [ ! -L "$1" ] || fail "administrative directory is a symlink: $1"
    if [ -e "$1" ]; then
        [ -d "$1" ] && [ "$(stat -c %u "$1")" -eq 0 ] || fail "administrative directory is not root-owned: $1"
        permissions=$(stat -c %a "$1")
        [ "$((0$permissions & 022))" -eq 0 ] || fail "administrative directory is writable by another identity: $1"
    fi
}
for directory in "$state" "${state%/*}" "$etc_root" "${etc_root%/*}" "$profiles" "${profiles%/*}" "$nix_conf" "${nix_conf%/*}"; do
    check_directory "$directory"
done
check_directory "$generation"
for directory in "$state/services" "$state/bin" "$state/authorized_keys" "$state/services"/*; do
    if [ -e "$directory" ] || [ -L "$directory" ]; then check_directory "$directory"; fi
done
for file in passwd group nix/nix.conf; do [ -f "$generation/etc/$file" ] || fail "missing etc/$file"; done
for directory in profiles services authorized_keys; do
    [ -d "$generation/$directory" ] || fail "missing $directory"
    for entry in "$generation/$directory"/*; do
        [ -e "$entry" ] || { [ ! -L "$entry" ] || fail "broken link: $entry"; continue; }
        name=${entry##*/}; valid_name "$name" || fail "invalid $directory name: $name"
        case $directory in
            profiles)
                case $name in nns-system|system-profile) fail "reserved profile: $name";; esac
                [ -d "$entry/bin" ] || fail "profile has no bin directory: $name";;
            services)
                [ -x "$entry/run" ] || fail "service run script is not executable: $name"
                [ ! -f "$entry/oneshot" ] || [ -x "$entry/finish" ] || fail "oneshot has no finish script: $name";;
            authorized_keys) [ -f "$entry" ] || fail "invalid authorized keys: $name";;
        esac
    done
done
[ -x "$launcher" ] && [ "$(stat -c %u "$launcher")" -eq 0 ] || fail 'namespace launcher is not root-owned and executable'
permissions=$(stat -c %a "$launcher")
[ "$((0$permissions & 022))" -eq 0 ] || fail 'namespace launcher is writable by another identity'
check_directory "${launcher%/*}"
root_home=$(grep '^root:' "$generation/etc/passwd" | cut -d: -f6)
[ -n "$root_home" ] || fail 'missing root home'
check_directory "$root_home"
if [ -f "$generation/sshd-enabled" ]; then
    [ -f "$generation/sshd_config" ] && [ -x "$generation/check-sshd" ] || fail 'incomplete SSH generation'
    [ -x "$launcher" ] && [ -x "$sp/bin/ssh-keygen" ] || fail 'SSH bootstrap tools unavailable'
fi

umask 077
mkdir -p "${state%/*}"
[ ! -L "$state.lock" ] || fail 'activation lock is a symlink'
exec 9>"$state.lock"
flock 9
export NNS_SERVICE_LOCKED=1
mkdir -p "$state" "$etc_root" "$profiles" "$nix_conf" "$state/services" "$state/authorized_keys" "$root_home"
# Refuse legacy app-owned service trees rather than following their links as root.
for directory in "$state/services" "$state/authorized_keys" "$etc_root/nix" "$etc_root/ssl" "$etc_root/ssl/certs"; do check_directory "$directory"; done
chmod 755 "$state"
chmod 700 "$state/services" "$state/authorized_keys" "$root_home"
chmod 755 "$etc_root" "$profiles" "$nix_conf"
if [ -f "$generation/sshd-enabled" ] && [ ! -f "$state/ssh_host_ed25519_key" ]; then
    "$sp/bin/ssh-keygen" -q -t ed25519 -N '' -f "$state/ssh_host_ed25519_key"
fi
if [ -f "$generation/sshd-enabled" ]; then
    [ ! -L "$state/ssh_host_ed25519_key" ] && [ "$(stat -c %u "$state/ssh_host_ed25519_key")" -eq 0 ] || fail 'host key is not root-owned'
    chmod 600 "$state/ssh_host_ed25519_key"
    # The launcher supplies private /var/empty without changing the host.
    "$generation/check-sshd" "$generation/etc" "$generation/sshd_config"
fi

service_control() {
    if [ -x "$generation/service-control" ]; then "$generation/service-control" "$1";
    else sh "${NNS_SERVICE_RUNTIME:-${0%/*}/service-runtime.sh}" "$generation" "$1"; fi
}
# Validate the selected backend, migration protocol and candidate database before
# publishing configuration or profiles. This does not stop the current manager.
service_control preflight

# Keep the staged etc directory inode, including its live bind mounts.
# Copy the small generated tree; do not replace Android /etc or delete unknown files.
find -L "$generation/etc" -type f | while IFS= read -r source; do
    relative=${source#"$generation/etc/"}
    destination=$etc_root/$relative
    check_directory "${destination%/*}"
    install -d -m 755 "${destination%/*}"
    temporary=${destination%/*}/.nns-${destination##*/}.$$
    install -m 644 "$source" "$temporary"
    mv -Tf "$temporary" "$destination"
done
install -m 644 "$generation/etc/nix/nix.conf" "$nix_conf/.nix.conf.$$"
mv -Tf "$nix_conf/.nix.conf.$$" "$nix_conf/nix.conf"

# Profile publication must also work at boot, before the daemon exists.
export NIX_REMOTE=local NIX_CONF_DIR="$nix_conf"
# Ordinary profiles retain their prior generations as garbage-collection roots.
"$sp/bin/nix-env" --profile "$profiles/system-profile" --set "$(readlink -f "$sp")"
# Delegate only the standard per-user profile directories, not their
# administrative parent. These roots remain visible before Android unlock.
check_directory "$profiles/per-user"
mkdir -p "$profiles/per-user"
chmod 755 "$profiles/per-user"
while IFS=: read -r name _ uid gid _; do
    [ "$uid" -ne 0 ] || continue
    directory=$profiles/per-user/$name
    [ ! -L "$directory" ] || fail "per-user profile directory is a symlink: $name"
    if [ -e "$directory" ]; then
        owner=$(stat -c %u "$directory")
        [ "$owner" = 0 ] || [ "$owner" = "$uid" ] || fail "unexpected per-user profile owner: $name"
    fi
    mkdir -p "$directory"
    chown "$uid:$gid" "$directory"
    chmod 755 "$directory"
done < "$generation/etc/passwd"
for entry in "$generation/profiles"/*; do
    [ -e "$entry" ] || continue
    "$sp/bin/nix-env" --profile "$profiles/${entry##*/}" --set "$(readlink -f "$entry")"
done
for entry in "$generation/authorized_keys"/*; do
    [ -e "$entry" ] || continue
    install -m 600 "$entry" "$state/authorized_keys/.${entry##*/}.$$"
    mv -Tf "$state/authorized_keys/.${entry##*/}.$$" "$state/authorized_keys/${entry##*/}"
done
for entry in "$state/authorized_keys"/*; do
    [ -f "$entry" ] || continue
    [ -f "$generation/authorized_keys/${entry##*/}" ] || rm -f "$entry"
done
if [ -f "$generation/sshd-enabled" ]; then
    install -m 600 "$generation/sshd_config" "$state/.sshd_config.$$"
    mv -Tf "$state/.sshd_config.$$" "$state/sshd_config"
fi
# The nns-system profile belongs to deploy-rs, not this activation script.
service_control activate
if [ -d "$generation/services/nix-daemon" ]; then
    attempts=0
    until NIX_REMOTE=daemon "$sp/bin/nix" --extra-experimental-features nix-command store ping --store daemon >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 30 ] || fail 'Nix daemon did not become available'
        sleep 1
    done
fi
