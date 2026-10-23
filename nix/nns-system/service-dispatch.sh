#!/bin/sh
# NNS policy only: native managers own dependencies and successful finite state.
set -eu
backend=$1
state=$2
exec >>"$state/supervisor.log" 2>&1
completed_phase=
requested_phase=
while :; do
    generation=$(readlink -f "$state/manager-generation")
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
            *) exit 1;;
        esac
        requested_phase=$selection
        if [ "$successful" = true ]; then completed_phase=$selection; fi
    fi
    if [ "$completed_phase" = "$generation/all-services" ]; then
        # The startup transition is complete. Do not keep reasserting "up"
        # against native operator commands or retain an idle policy process.
        case $backend in
            s6-rc) s6-svc -O "$state/managers/s6-rc/scan/svc-nns-dispatcher";;
            dinit) dinitctl --quiet --socket-path "$state/managers/dinit/control" stop --no-wait svc-nns-dispatcher;;
        esac
        exit 0
    fi
    sleep 1
done
