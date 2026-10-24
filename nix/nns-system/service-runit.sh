# shellcheck shell=sh
# shellcheck disable=SC2154 # Parent runtime supplies these globals.

# Runit has no policy process to restore. Its scanner owns every supervisor,
# and a failed activation leaves the scanner running.
backend_resume_after_failure() {
    :
}
# Runit state needs no preparation beyond the checks the runtime already ran.
backend_preflight() {
    :
}
backend_prepare() {
    :
}
backend_activate() {
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
backend_stop() {
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
