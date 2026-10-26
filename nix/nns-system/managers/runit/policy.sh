# shellcheck shell=sh
# shellcheck disable=SC2154 # Globals are shared with the dispatcher.

# Runit has no dependency engine. Readiness is a running process for a longrun
# and a completion record for a finite action.
manager_ready() {
    directory=$state/services/$1
    if [ -f "$directory/oneshot" ]; then
        [ -f "$directory/completed" ]
    else
        sv status "$directory" 2>/dev/null | grep -q '^run:'
    fi
}
manager_dependencies_ready() {
    [ -f "$generation/services/$1/after" ] || return 0
    while IFS= read -r dependency; do
        [ -z "$dependency" ] || manager_ready "$dependency" || return 1
    done < "$generation/services/$1/after"
}
# Start every service whose dependencies are ready in the same pass. Independent
# services never wait behind a failing branch.
manager_apply() {
    selection=$1
    set --
    while IFS= read -r identifier; do [ -z "$identifier" ] || set -- "$@" "$identifier"; done < "$selection"
    for identifier in "$@"; do
        name=${identifier#svc-}
        if manager_ready "$name"; then continue; fi
        successful=false
        manager_dependencies_ready "$name" || continue
        # sv up starts the process but leaves a down file behind, and a stale
        # down file would stop runsv from restarting it.
        rm -f "$state/services/$name/down"
        sv up "$state/services/$name" || :
    done
}
# Runit owns no native operator channel. A resident process re-evaluates the
# next published generation without reasserting a completed phase.
manager_complete() {
    :
}
