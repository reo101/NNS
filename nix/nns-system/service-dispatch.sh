#!/bin/sh
# NNS policy loop. The selected service manager supplies phase application and
# completion in its policy file; this process owns only the phase state machine.
set -eu
state=$1
exec >>"$state/supervisor.log" 2>&1
completed_phase=
requested_phase=
while :; do
    # A boot before the first activation has no published generation yet.
    generation=$(readlink -f "$state/manager-generation" 2>/dev/null) || generation=
    if [ -z "$generation" ]; then sleep 1; continue; fi
    policy=$generation/service-manager-policy.sh
    if [ ! -f "$policy" ]; then sleep 1; continue; fi
    # shellcheck disable=SC1090
    . "$policy"
    selection=$generation/boot-services
    if [ "$(/system/bin/getprop sys.user.0.ce_available)" = true ]; then selection=$generation/all-services; fi
    if [ "$selection" != "$completed_phase" ]; then
        successful=true
        manager_apply "$selection"
        requested_phase=$selection
        if [ "$successful" = true ]; then completed_phase=$selection; fi
    fi
    if [ "$completed_phase" = "$generation/all-services" ]; then
        manager_complete
    fi
    sleep 1
done
