# shellcheck shell=sh
# shellcheck disable=SC2154 # Globals are shared with the dispatcher.

manager_apply() {
    # Phase variables name immutable input files, not output files.
    # shellcheck disable=SC2094
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        # Do not turn an explicit operator stop into a retry.
        if [ "$1" != "$requested_phase" ] ||
            dinitctl --quiet --socket-path "$state/managers/dinit/control" is-failed "$name"; then
            dinitctl --quiet --socket-path "$state/managers/dinit/control" start --no-wait "$name" || successful=false
        fi
        dinitctl --quiet --socket-path "$state/managers/dinit/control" is-started "$name" || successful=false
    done < "$1"
}
manager_complete() {
    dinitctl --quiet --socket-path "$state/managers/dinit/control" stop --no-wait svc-nns-dispatcher
    exit 0
}
