# shellcheck shell=sh
# shellcheck disable=SC2154 # Parent runtime supplies these globals.

# Runit has no policy process to restore. Its scanner owns every supervisor,
# and a failed activation leaves the scanner running.
backend_resume_after_failure() {
    :
}
backend_preflight() {
    command -v sv >/dev/null 2>&1 || fail 'runit control executable is unavailable'
    [ -x "$sp/bin/runsvdir" ] || fail 'runit supervisor executable is unavailable'
}
# Runit publishes its own service tree; the generic change tracker is unused.
backend_prepare() {
    :
}
backend_activate() {
    start_scanner=false
    if ! manager_running; then start_scanner=true; fi
    # Stop the policy process before touching the tree. A running instance reads
    # the published generation and would start services while they change.
    dispatcher=$state/services/nns-dispatcher
    if sv status "$dispatcher" >/dev/null 2>&1; then sv -w 10 down "$dispatcher" || :; fi
    for directory in "$state/services"/*; do
        [ -e "$directory" ] || continue
        check_directory "$directory"
        if [ ! -d "$generation/services/${directory##*/}" ]; then
            : > "$directory/down"
            sv -w 10 force-shutdown "$directory" >/dev/null 2>&1 || :
            sv -w 10 exit "$directory" >/dev/null 2>&1 || :
            rm -rf -- "$directory"
        fi
    done
    # Invalidate all finite results before publishing any replacement definition.
    for entry in "$generation/services"/*; do
        [ -e "$entry" ] || continue
        directory=$state/services/${entry##*/}
        if [ -f "$entry/oneshot" ] || [ -f "$directory/oneshot" ]; then
            if sv status "$directory" >/dev/null 2>&1; then sv -w 10 down "$directory" || :; fi
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
            # A scanner start must not autostart anything except the policy
            # process, which starts services in dependency order.
            if [ "$start_scanner" = true ]; then
                if [ "${entry##*/}" = nns-dispatcher ]; then
                    rm -f "$destination/down"
                else
                    : > "$destination/down"
                fi
            fi
        fi
        if [ "$destination" != "$directory" ]; then mv -T "$destination" "$directory"; fi
        # A changed longrun stops here. The policy process starts it again only
        # when its dependencies are ready, so the change cannot bypass gating.
        if [ ! -f "$entry/oneshot" ] && { [ "$previous_run" != "$target" ] || [ "$previous_oneshot" = true ]; } && sv status "$directory" >/dev/null 2>&1; then
            sv -w 10 down "$directory" || :
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
    # The policy process starts every service, including finite actions. The
    # scanner autostarts it at boot; a reapplication starts it here.
    sv up "$state/services/nns-dispatcher" || :
}
backend_stop() {
    # Stop the scanner first: it must not recreate supervisors during teardown.
    if manager_running; then kill -TERM "$(cat "$state/supervisor.pid")"; wait_supervisor_exit; fi
    # Terminate every surviving supervisor. A failed status read must not leave
    # a runsv alive after its directory is removed.
    for directory in "$state/services"/*; do
        [ -d "$directory" ] || continue
        [ -p "$directory/supervise/control" ] || continue
        : > "$directory/down"
        sv -w 10 force-shutdown "$directory" >/dev/null 2>&1 || :
        sv -w 10 exit "$directory" >/dev/null 2>&1 || :
    done
}
