# shellcheck shell=sh
# shellcheck disable=SC2154,SC2034 # Globals are shared with the parent runtime.

# sv prints success and failure reports to stdout. Keep failure diagnostics,
# but do not turn a successful reconciliation into a transcript of sv commands.
runit_control() (
    if output=$(sv -w 10 "$@" 2>&1); then
        exit 0
    else
        status=$?
        printf 'nns services: runit %s failed (status %s)\n%s\n' "$*" "$status" "$output" >&2
        exit "$status"
    fi
)
runit_wait_supervised() (
    attempts=0
    until sv status "$1" >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 100 ]; then
            printf 'nns services: runit supervisor did not become available: %s\n' "$1" >&2
            sv status "$1" >&2 || :
            exit 1
        fi
        sleep 0.1
    done
)
runit_start_dispatcher() {
    runit_wait_supervised "$state/services/nns-dispatcher" || return
    runit_control start "$state/services/nns-dispatcher"
}
backend_resume_after_failure() {
    runit_start_dispatcher
}
backend_preflight() {
    command -v sv >/dev/null 2>&1 || fail 'runit control executable is unavailable'
    [ -x "$sp/bin/runsvdir" ] || fail 'runit supervisor executable is unavailable'
    for directory in "$state/services"/.retiring-*; do
        if [ -e "$directory" ] || [ -L "$directory" ]; then check_directory "$directory"; fi
    done
}
# Change intent must survive a failed stop even when some run links were already
# published. The runtime clears pending-update only after activation succeeds.
backend_prepare() {
    prepare_changes
}
runit_stop_service() {
    if sv status "$1" >/dev/null 2>&1; then
        runit_control down "$1" || return
    elif [ "$start_scanner" = false ]; then
        runit_wait_supervised "$1" || return
        runit_control down "$1" || return
    fi
}
runit_shutdown() {
    # A service that was never supervised has no supervisor to stop. For a
    # stale supervision directory, sv shutdown confirms that runsv is absent.
    if [ -d "$1/supervise" ]; then
        runit_control shutdown "$1" || return
    fi
}
runit_remove_retired() {
    for retired in "$state/services"/.retiring-*; do
        [ -d "$retired" ] || continue
        check_directory "$retired"
        runit_shutdown "$retired" || fail "cannot retire runit service: $retired"
        rm -rf -- "$retired"
    done
}
backend_activate() {
    start_scanner=false
    if ! manager_running; then start_scanner=true; fi
    # Arm cleanup before stopping: the command can take effect and still fail.
    dispatcher=$state/services/nns-dispatcher
    if [ -d "$dispatcher" ]; then
        resume_pending=1
        runit_stop_service "$dispatcher" || fail 'cannot stop the runit dispatcher for update'
    fi
    runit_remove_retired
    for directory in "$state/services"/*; do
        [ -e "$directory" ] || continue
        check_directory "$directory"
        if [ ! -d "$generation/services/${directory##*/}" ]; then
            : > "$directory/down"
            # Hide the directory before shutdown so the scanner cannot recreate
            # runsv. A failed shutdown leaves it here for the next retry.
            mv -T "$directory" "$state/services/.retiring-${directory##*/}"
        fi
    done
    runit_remove_retired
    # Stop finite actions before invalidating their results. Do not publish a
    # replacement over a process whose stop was not confirmed.
    for entry in "$generation/services"/*; do
        [ -d "$entry" ] || continue
        directory=$state/services/${entry##*/}
        if [ -d "$directory" ] && { [ -f "$entry/oneshot" ] || [ -f "$directory/oneshot" ]; }; then
            runit_stop_service "$directory" || fail "cannot stop finite service: ${entry##*/}"
            rm -f "$directory/completed" "$directory/exit-status"
        fi
    done
    for entry in "$generation/services"/*; do
        [ -d "$entry" ] || continue
        name=${entry##*/}
        directory=$state/services/$name
        check_directory "$directory"
        target=$(readlink -f "$entry/run")
        destination=$directory
        if [ ! -d "$directory" ]; then destination=$(mktemp -d "$state/.service.$name.XXXXXXXX"); fi
        chmod 700 "$destination"
        if grep -Fxq "svc-$name" "$updates/changed"; then
            : > "$destination/pending-update"
            if [ -d "$directory" ] && [ "$name" != nns-dispatcher ] && [ ! -f "$entry/oneshot" ]; then
                runit_stop_service "$directory" || fail "cannot stop changed service: $name"
            fi
        fi
        # Newly discovered services must wait for the policy process. Unchanged
        # longruns retain their live processes and existing startup state.
        if [ "$destination" != "$directory" ] || [ "$start_scanner" = true ] || [ -f "$destination/pending-update" ] || [ -f "$entry/oneshot" ]; then
            : > "$destination/down"
        fi
        ln -s "$target" "$destination/.run.$$"
        mv -Tf "$destination/.run.$$" "$destination/run"
        if [ -f "$entry/oneshot" ]; then
            : > "$destination/oneshot"
            ln -s "$(readlink -f "$entry/finish")" "$destination/.finish.$$"
            mv -Tf "$destination/.finish.$$" "$destination/finish"
        else
            rm -f "$destination/oneshot" "$destination/finish"
        fi
        if [ "$destination" != "$directory" ]; then mv -T "$destination" "$directory"; fi
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
    # Wait for a live supervisor, then confirm the dispatcher starts. Finite
    # actions and unlock-gated services remain asynchronous.
    runit_start_dispatcher || fail 'cannot start the runit dispatcher'
    resume_pending=
}
backend_stop() {
    start_scanner=false
    if ! manager_running; then start_scanner=true; fi
    if [ -d "$state/services/nns-dispatcher" ]; then
        runit_stop_service "$state/services/nns-dispatcher" || fail 'cannot stop the runit dispatcher for shutdown'
    fi
    # Stop the scanner first: it must not recreate supervisors during teardown.
    if manager_running; then kill -TERM "$(cat "$state/supervisor.pid")"; wait_supervisor_exit; fi
    for directory in "$state/services"/* "$state/services"/.retiring-*; do
        [ -d "$directory" ] || continue
        check_directory "$directory"
        : > "$directory/down"
        runit_shutdown "$directory" || fail "cannot stop runit supervision: $directory"
    done
}
