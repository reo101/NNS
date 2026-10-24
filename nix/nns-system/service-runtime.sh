#!/bin/sh
set -eu
fail() { printf 'nns services: %s\n' "$*" >&2; exit 1; }
# A native reconciliation that aborts must restore the policy process. The
# dispatcher is paused or stopped for a database switch, and leaving it stopped
# hides native state from the next activation and from operator control tools.
resume_pending=
updates=
resume_policy_process() {
    [ -n "${resume_pending:-}" ] || return 0
    resume_pending=
    backend_resume_after_failure
}
service_exit_cleanup() {
    status=$?
    resume_policy_process
    if [ -n "$updates" ] && [ -d "$updates" ]; then rm -rf -- "$updates"; fi
    return "$status"
}
trap service_exit_cleanup EXIT
[ "$(id -u)" -eq 0 ] || fail 'service control requires root'
[ "$#" -ge 2 ] || fail 'usage: service-runtime.sh GENERATION preflight|activate|stop'
generation=$1
operation=$2
sp=$generation/system-profile
export PATH="$sp/bin:/system/bin:/system/xbin"
state=${NNS_STATE_DIRECTORY:-/data/nix/var/nns}
etc_root=${NNS_ETC_DIRECTORY:-/data/nix/var/daemon-etc}
launcher=${NNS_LAUNCHER:-/data/nix/bin/nix-enter}
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
backend_of() {
    if [ -f "$1/service-backend" ]; then cat "$1/service-backend"; else printf 'runit\n'; fi
}
backend=$(backend_of "$generation")
if [ -f "$generation/service-protocol" ]; then
    [ "$(cat "$generation/service-protocol")" = 1 ] || fail 'unsupported candidate service protocol'
    [ -x "$generation/service-control" ] || fail 'candidate service controller is missing'
else
    fail 'generation has no service protocol'
fi
case $backend in ''|*[!A-Za-z0-9_-]*) fail "invalid backend name: $backend";; esac
runtime=$state/managers/$backend
for directory in "$generation" "$state" "${state%/*}" "$state/services" "$state/bin" "$state/managers" "$runtime"; do check_directory "$directory"; done
for directory in "$state/services"/*; do
    if [ -e "$directory" ] || [ -L "$directory" ]; then check_directory "$directory"; fi
done
umask 077
[ ! -L "$state.lock" ] || fail 'activation lock is a symlink'
if [ "${NNS_SERVICE_LOCKED:-0}" != 1 ]; then
    exec 9>"$state.lock"
    flock 9
fi
export NNS_SERVICE_LOCKED=1
boot_id=$(cat /proc/sys/kernel/random/boot_id) || fail 'cannot read kernel boot identity'
[ -n "$boot_id" ] || fail 'kernel boot identity is empty'
for file in supervisor.pid manager-process supervisor.log; do
    [ ! -L "$state/$file" ] || fail "mutable service state is a symlink: $file"
    if [ -e "$state/$file" ]; then
        [ -f "$state/$file" ] && [ "$(stat -c %u "$state/$file")" -eq 0 ] || fail "mutable service state is not a root-owned file: $file"
        permissions=$(stat -c %a "$state/$file")
        [ "$((0$permissions & 022))" -eq 0 ] || fail "mutable service state is writable by another identity: $file"
    fi
done
previous=
if [ -e "$state/manager-generation" ] || [ -L "$state/manager-generation" ]; then
    [ -L "$state/manager-generation" ] || fail 'manager-generation is not a symlink'
    previous=$(readlink -f "$state/manager-generation")
    check_directory "$previous"
    check_directory "${previous%/*}"
    [ -f "$previous/service-protocol" ] && [ "$(cat "$previous/service-protocol")" = 1 ] && [ -x "$previous/service-control" ] || fail 'unsupported previous service protocol'
fi
# Include boot identity: a PID and its start time can both recur after reboot.
process_identity() (
    case $1 in ''|0|1|*[!0-9]*) exit 1;; esac
    [ -r "/proc/$1/stat" ] || exit 1
    data=$(cat "/proc/$1/stat") || exit 1
    fields=${data##*) }
    # Linux stat fields after the parenthesized command are space-separated.
    # shellcheck disable=SC2086
    set -- $fields
    case $1 in Z|X) exit 1;; esac
    shift 19
    printf '%s %s\n' "$1" "$boot_id"
)
manager_running() (
    [ -f "$state/supervisor.pid" ] || exit 1
    pid=$(cat "$state/supervisor.pid")
    identity=$(process_identity "$pid") || exit 1
    if [ -f "$state/manager-process" ]; then
        [ "$(cat "$state/manager-process")" = "$pid $identity" ]
    else
        # Adopt only the legacy scanner for this exact administrative tree.
        [ "$backend" = runit ] && grep -aq 'runsvdir' "/proc/$pid/cmdline" &&
            tr '\000' '\n' < "/proc/$pid/cmdline" | grep -Fxq "$state/services"
    fi
)
start_supervisor() {
    # Transfer the lock only through registration. If activation dies after
    # fork, the child records ownership before another activation can proceed.
    # Closing the acknowledgement pipe also proves that FD 9 is closed.
    supervisor_pid=$(
        # Expansion belongs to the registration interpreter, not this shell.
        # shellcheck disable=SC2016
        nohup "$sp/bin/sh" -eu -c '
            state=$1; boot_id=$2; launcher=$3; etc_root=$4; sp=$5; shift 5
            started=$(
                data=$(cat "/proc/$$/stat")
                fields=${data##*) }
                set -f
                set -- $fields
                shift 19
                printf "%s" "$1"
            )
            temporary=$(mktemp "$state/.supervisor.XXXXXXXX")
            printf "%s\n" "$$" > "$temporary"
            mv -Tf "$temporary" "$state/supervisor.pid"
            temporary=$(mktemp "$state/.manager-process.XXXXXXXX")
            printf "%s %s %s\n" "$$" "$started" "$boot_id" > "$temporary"
            mv -Tf "$temporary" "$state/manager-process"
            exec 9>&-
            printf "%s\n" "$$"
            exec >>"$state/supervisor.log" 2>&1
            export NNS_SERVICE_LOCKED=0
            exec "$launcher" --etc "$etc_root" -- "$sp/bin/env" "PATH=$sp/bin:/system/bin:/system/xbin" "$@"
        ' nns-supervisor "$state" "$boot_id" "$launcher" "$etc_root" "$sp" "$@" </dev/null 2>>"$state/supervisor.log" &
    )
    case $supervisor_pid in
        ''|0|1|*[!0-9]*)
            rm -f "$state/supervisor.pid" "$state/manager-process"
            fail 'supervisor registration failed';;
    esac
}
wait_supervisor_exit() {
    attempts=0
    while manager_running; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 15 ] || fail 'previous manager did not exit'
        sleep 1
    done
}
publish_generation() {
    [ -f "$generation/service-protocol" ] || return 0
    ln -s "$generation" "$state/.manager-generation.$$"
    mv -Tf "$state/.manager-generation.$$" "$state/manager-generation"
}
invalidate_oneshots() {
    while IFS= read -r identifier; do
        name=${identifier#svc-}
        rm -f "$state/services/$name/completed" "$state/services/$name/exit-status"
    done < "$updates/finite"
}
prepare_changes() {
    updates=$(mktemp -d "$state/.service-update.XXXXXXXX")
    : > "$updates/changed"; : > "$updates/removed"; : > "$updates/finite"
    for directory in "$state/services"/*; do
        [ -d "$directory" ] || continue
        name=${directory##*/}; valid_name "$name" || fail "invalid service: $name"
        [ -d "$generation/services/$name" ] || printf 'svc-%s\n' "$name" >> "$updates/removed"
        if [ -f "$directory/oneshot" ]; then printf 'svc-%s\n' "$name" >> "$updates/finite"; fi
    done
    for entry in "$generation/services"/*; do
        [ -d "$entry" ] || continue
        name=${entry##*/}; valid_name "$name" || fail "invalid service: $name"
        if [ -f "$state/services/$name/pending-update" ] ||
            [ "$(readlink "$state/services/$name/run" 2>/dev/null || :)" != "$(readlink -f "$entry/run")" ]; then
            printf 'svc-%s\n' "$name" >> "$updates/changed"
        fi
        if [ -f "$entry/oneshot" ]; then printf 'svc-%s\n' "$name" >> "$updates/finite"; fi
    done
}
publish_services() {
    for entry in "$generation/services"/*; do
        [ -d "$entry" ] || continue
        directory=$state/services/${entry##*/}
        check_directory "$directory"
        mkdir -p "$directory"; chmod 700 "$directory"
        # Keep intent dirty until native reconciliation succeeds. A failed stop
        # must not make a retry mistake the intended command for the live one.
        if grep -Fxq "svc-${entry##*/}" "$updates/changed"; then : > "$directory/pending-update"; fi
        ln -s "$(readlink -f "$entry/run")" "$directory/.run.$$"
        mv -Tf "$directory/.run.$$" "$directory/run"
        if [ -f "$entry/oneshot" ]; then : > "$directory/oneshot"; else rm -f "$directory/oneshot"; fi
        rm -f "$directory/finish" "$directory/down"
    done
}
remove_obsolete_services() {
    while IFS= read -r identifier; do rm -rf -- "$state/services/${identifier#svc-}"; done < "$updates/removed"
}
# The backend controller supplies backend_preflight, backend_prepare,
# backend_activate, backend_stop, and backend_resume_after_failure. The
# runtime owns locking, state validation, supervisor registration, and
# generation publication.
# shellcheck disable=SC1090
controller=$generation/service-backend.sh
[ -f "$controller" ] || fail 'generation has no service backend controller'
. "$controller"
# A backend change must not inherit a legacy runit tree whose supervisors the
# new backend cannot own. Only the first backend-aware activation is affected.
require_no_legacy_state() {
    [ -n "$previous" ] && return 0
    [ ! -e "$state/supervisor.pid" ] || fail 'activate a backend-aware runit generation before changing backend'
    for directory in "$state/services"/*; do
        [ ! -e "$directory" ] || fail 'activate a backend-aware runit generation before changing backend'
    done
}
preflight() {
    backend_preflight
}
case $operation in
    preflight) preflight;;
    activate)
        preflight
        if [ -n "$previous" ] && [ "$(backend_of "$previous")" != "$backend" ]; then
            "$previous/service-control" stop
            rm -f "$state/supervisor.pid" "$state/manager-process"
            rm -rf -- "$state/services"
            mkdir -m 700 "$state/services"
        fi
        publish_generation
        backend_prepare
        backend_activate
        for entry in "$generation/services"/*; do
            [ ! -d "$entry" ] || rm -f "$state/services/${entry##*/}/pending-update"
        done
        ;;
    stop)
        if [ -n "$previous" ] && [ "$(backend_of "$previous")" != "$backend" ]; then
            "$previous/service-control" stop
        else
            backend_stop
        fi
        rm -f "$state/supervisor.pid" "$state/manager-process"
        ;;
    *) fail "unknown operation: $operation";;
esac