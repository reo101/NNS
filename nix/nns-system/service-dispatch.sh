#!/bin/sh
# NNS policy only: native managers own dependencies and successful finite state.
set -eu
backend=$1
state=$2
exec >>"$state/supervisor.log" 2>&1
completed_phase=
requested_phase=
# Runit has no dependency engine. Readiness is a running process for a longrun
# and a completion record for a finite action.
runit_ready() {
    directory=$state/services/$1
    if [ -f "$directory/oneshot" ]; then
        [ -f "$directory/completed" ]
    else
        sv status "$directory" 2>/dev/null | grep -q '^run:'
    fi
}
runit_dependencies_ready() {
    [ -f "$generation/services/$1/after" ] || return 0
    while IFS= read -r dependency; do
        [ -z "$dependency" ] || runit_ready "$dependency" || return 1
    done < "$generation/services/$1/after"
}
while :; do
    # A boot before the first activation has no published generation yet.
    generation=$(readlink -f "$state/manager-generation" 2>/dev/null) || generation=
    if [ -z "$generation" ]; then sleep 1; continue; fi
    selection=$generation/boot-services
    if [ "$(/system/bin/getprop sys.user.0.ce_available)" = true ]; then selection=$generation/all-services; fi
    if [ "$selection" != "$completed_phase" ]; then
        successful=true
        case $backend in
            s6-rc)
                set --
                while IFS= read -r name; do [ -z "$name" ] || set -- "$@" "$name"; done < "$selection"
                if [ "$#" -gt 0 ]; then
                    s6-rc -b -l "$state/managers/s6-rc/live" -u change "$@" || successful=false
                fi
                ;;
            dinit)
                # Phase variables name immutable input files, not output files.
                # shellcheck disable=SC2094
                while IFS= read -r name; do
                    [ -n "$name" ] || continue
                    # Do not turn an explicit operator stop into a retry.
                    if [ "$selection" != "$requested_phase" ] ||
                        dinitctl --quiet --socket-path "$state/managers/dinit/control" is-failed "$name"; then
                        dinitctl --quiet --socket-path "$state/managers/dinit/control" start --no-wait "$name" || successful=false
                    fi
                    dinitctl --quiet --socket-path "$state/managers/dinit/control" is-started "$name" || successful=false
                done < "$selection"
                ;;
            runit)
                # Start every service whose dependencies are ready in the same
                # pass. Independent services never wait behind a failing branch.
                set --
                while IFS= read -r name; do [ -z "$name" ] || set -- "$@" "$name"; done < "$selection"
                for identifier in "$@"; do
                    name=${identifier#svc-}
                    if runit_ready "$name"; then continue; fi
                    successful=false
                    if ! runit_dependencies_ready "$name"; then continue; fi
                    # sv up starts the process but leaves a down file behind, and
                    # a stale down file would stop runsv from restarting it.
                    rm -f "$state/services/$name/down"
                    sv up "$state/services/$name" || :
                done
                ;;
            *) exit 1;;
        esac
        requested_phase=$selection
        if [ "$successful" = true ]; then completed_phase=$selection; fi
    fi
    if [ "$completed_phase" = "$generation/all-services" ]; then
        # The startup transition is complete. Do not keep reasserting "up"
        # against native operator commands or retain an idle policy process.
        # Runit keeps the process resident: it owns no native operator channel,
        # and a resident process re-evaluates the next published generation.
        case $backend in
            s6-rc) s6-svc -O "$state/managers/s6-rc/scan/svc-nns-dispatcher"; exit 0;;
            dinit) dinitctl --quiet --socket-path "$state/managers/dinit/control" stop --no-wait svc-nns-dispatcher; exit 0;;
            runit) sleep 1; continue;;
        esac
    fi
    sleep 1
done
