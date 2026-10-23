#!/bin/sh
set -eu
fail() { printf 'nns services: %s\n' "$*" >&2; exit 1; }
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
    [ "$backend" = runit ] || fail 'native generation has no service protocol'
fi
case $backend in runit|s6-rc|dinit) ;; *) fail "unknown backend: $backend";; esac
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
    trap 'rm -rf -- "$updates"' EXIT
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
runit_activate() {
    start_scanner=false
    if ! manager_running; then start_scanner=true; fi
    for directory in "$state/services"/*; do
        [ -e "$directory" ] || continue
        check_directory "$directory"
        if [ ! -d "$generation/services/${directory##*/}" ]; then
            if [ -p "$directory/supervise/control" ] && sv status "$directory" >/dev/null 2>&1; then
                sv -w 10 down "$directory"; sv -w 10 exit "$directory"
            fi
            rm -rf -- "$directory"
        fi
    done
    # Invalidate all finite results before publishing any replacement definition.
    for entry in "$generation/services"/*; do
        [ -e "$entry" ] || continue
        directory=$state/services/${entry##*/}
        if [ -f "$entry/oneshot" ] || [ -f "$directory/oneshot" ]; then
            if [ -p "$directory/supervise/control" ] && sv status "$directory" >/dev/null 2>&1; then sv -w 10 down "$directory"; fi
            rm -f "$directory/completed" "$directory/exit-status"
        fi
    done
    for entry in "$generation/services"/*; do
        [ -e "$entry" ] || continue
        directory=$state/services/${entry##*/}
        check_directory "$directory"
        previous_run=$(readlink "$directory/run" 2>/dev/null || :)
        target=$(readlink -f "$entry/run")
        previous_oneshot=false
        if [ -f "$directory/oneshot" ]; then previous_oneshot=true; fi
        destination=$directory
        if [ ! -d "$directory" ]; then destination=$(mktemp -d "$state/.service.${entry##*/}.XXXXXXXX"); fi
        chmod 700 "$destination"
        ln -s "$target" "$destination/.run.$$"
        mv -Tf "$destination/.run.$$" "$destination/run"
        if [ -f "$entry/oneshot" ]; then
            : > "$destination/oneshot"; : > "$destination/down"
            ln -s "$(readlink -f "$entry/finish")" "$destination/.finish.$$"
            mv -Tf "$destination/.finish.$$" "$destination/finish"
        else
            rm -f "$destination/oneshot" "$destination/finish"
            # A coordinated shutdown leaves down files for scanner safety.
            if [ "$previous_oneshot" = true ] || [ "$start_scanner" = true ]; then rm -f "$destination/down"; fi
        fi
        if [ "$destination" != "$directory" ]; then mv -T "$destination" "$directory"; fi
        if [ ! -f "$entry/oneshot" ] && { [ "$previous_run" != "$target" ] || [ "$previous_oneshot" = true ]; } && [ -p "$directory/supervise/control" ] && sv status "$directory" >/dev/null 2>&1; then
            sv -w 10 restart "$directory"
        fi
    done
    if ! manager_running; then start_supervisor "$sp/bin/runsvdir" "$state/services"; fi
    # Adopt a legacy scanner using one validated PID snapshot. Replace both
    # files so an old open descriptor cannot modify the new ownership record.
    if [ ! -f "$state/manager-process" ] && manager_running; then
        pid=$(cat "$state/supervisor.pid")
        identity=$(process_identity "$pid") || fail 'legacy supervisor identity changed'
        grep -aq 'runsvdir' "/proc/$pid/cmdline" || fail 'legacy supervisor command changed'
        tr '\000' '\n' < "/proc/$pid/cmdline" | grep -Fxq "$state/services" || fail 'legacy supervisor command changed'
        temporary=$(mktemp "$state/.supervisor.XXXXXXXX")
        printf '%s\n' "$pid" > "$temporary"
        mv -Tf "$temporary" "$state/supervisor.pid"
        temporary=$(mktemp "$state/.manager-process.XXXXXXXX")
        printf '%s %s\n' "$pid" "$identity" > "$temporary"
        mv -Tf "$temporary" "$state/manager-process"
    fi
    for entry in "$generation/services"/*; do
        [ -f "$entry/oneshot" ] || continue
        directory=$state/services/${entry##*/}; attempts=0
        until sv status "$directory" >/dev/null 2>&1; do
            attempts=$((attempts + 1)); [ "$attempts" -lt 10 ] || fail "oneshot is not supervised: ${entry##*/}"; sleep 1
        done
        sv up "$directory"
    done
}
runit_stop() {
    # Stop the scanner first: it must not recreate supervisors during teardown.
    if manager_running; then kill -TERM "$(cat "$state/supervisor.pid")"; wait_supervisor_exit; fi
    set --
    for directory in "$state/services"/*; do
        [ -d "$directory" ] || continue
        if [ -p "$directory/supervise/control" ] && sv status "$directory" >/dev/null 2>&1; then
            : > "$directory/down"
            set -- "$@" "$directory"
        fi
    done
    if [ "$#" -gt 0 ]; then sv -w 10 down "$@"; sv -w 10 exit "$@"; fi
}
dinit_control() { dinitctl --quiet --socket-path "$runtime/control" "$@"; }
dinit_preflight() {
    "$sp/bin/dinit" --version >/dev/null || fail 'Dinit executable is unavailable'
    "$sp/bin/dinitctl" --version >/dev/null || fail 'Dinit control executable is unavailable'
    check_directory "$runtime/services"
    if [ -f "$state/manager-process" ] && [ "$previous" != '' ] && [ "$(backend_of "$previous")" = dinit ] && ! manager_running; then
        case "$(cat "$state/manager-process")" in
            *" $boot_id") fail 'Dinit exited unexpectedly this boot; refusing to create a duplicate owner';;
        esac
    fi
    [ -d "$generation/service-definitions/services" ] || fail 'missing Dinit definitions'
}
dinit_activate() {
    if ! manager_running; then
        # The preflight rejects a same-boot manager crash with unknown children.
        rm -rf -- "$runtime/services"
    fi
    if manager_running; then
        dinit_control stop --force --ignore-unstarted svc-nns-dispatcher
        for list in changed finite removed; do
            while IFS= read -r identifier; do dinit_control stop --force --ignore-unstarted "$identifier"; done < "$updates/$list"
        done
    fi
    invalidate_oneshots
    mkdir -p "$runtime/services"
    for file in "$generation/service-definitions/services"/*; do
        name=${file##*/}; valid_name "$name" || fail "invalid Dinit definition: $name"
        ln -s "$(readlink -f "$file")" "$runtime/services/.$name.$$"
        mv -Tf "$runtime/services/.$name.$$" "$runtime/services/$name"
    done
    if manager_running; then
        while IFS= read -r identifier; do dinit_control reload "$identifier"; done < "$generation/all-services"
        cp "$updates/removed" "$updates/unload"
        while [ -s "$updates/unload" ]; do
            : > "$updates/remaining"; progress=false
            while IFS= read -r identifier; do
                if dinit_control unload "$identifier"; then progress=true; else printf '%s\n' "$identifier" >> "$updates/remaining"; fi
            done < "$updates/unload"
            [ "$progress" = true ] || fail 'cannot unload obsolete Dinit services'
            mv -Tf "$updates/remaining" "$updates/unload"
        done
        while IFS= read -r identifier; do rm -f "$runtime/services/$identifier"; done < "$updates/removed"
        dinit_control reload svc-nns-dispatcher
        dinit_control start --no-wait svc-nns-dispatcher
    else
        # A prior-boot socket is not evidence of a live manager.
        rm -f "$runtime/control"
        start_supervisor "$sp/bin/dinit" --system --container --services-dir "$runtime/services" --socket-path "$runtime/control" nns-runtime svc-nns-dispatcher
    fi
    attempts=0
    until dinit_control status svc-nns-dispatcher >/dev/null 2>&1; do
        attempts=$((attempts + 1)); [ "$attempts" -lt 10 ] || fail 'Dinit did not become available'; sleep 1
    done
    remove_obsolete_services
}
dinit_stop() {
    if manager_running; then
        dinit_control shutdown
        wait_supervisor_exit
    else
        dinit_preflight
    fi
}
# shellcheck disable=SC1090
if [ "$backend" = s6-rc ]; then . "${NNS_S6_RUNTIME:-${0%/*}/service-s6-rc.sh}"; fi
preflight() {
    if [ "$backend" != runit ] && [ -z "$previous" ]; then
        [ ! -e "$state/supervisor.pid" ] || fail 'activate a backend-aware runit generation before changing backend'
        for directory in "$state/services"/*; do
            [ ! -e "$directory" ] || fail 'activate a backend-aware runit generation before changing backend'
        done
    fi
    case $backend in s6-rc) backend_preflight;; dinit) dinit_preflight;; esac
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
        case $backend in
            runit) runit_activate;;
            *)
                mkdir -p "$state/managers" "$runtime"; chmod 700 "$state/managers" "$runtime"
                prepare_changes
                publish_services
                case $backend in s6-rc) backend_activate;; dinit) dinit_activate;; esac
                for entry in "$generation/services"/*; do
                    [ ! -d "$entry" ] || rm -f "$state/services/${entry##*/}/pending-update"
                done
                ;;
        esac
        ;;
    stop)
        if [ -n "$previous" ] && [ "$(backend_of "$previous")" != "$backend" ]; then
            "$previous/service-control" stop
        else
            case $backend in runit) runit_stop;; s6-rc) backend_stop;; dinit) dinit_stop;; esac
        fi
        rm -f "$state/supervisor.pid" "$state/manager-process"
        ;;
    *) fail "unknown operation: $operation";;
esac
