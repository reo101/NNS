# shellcheck shell=sh
# shellcheck disable=SC2154 # Globals are shared with the parent runtime.

dinit_control() { dinitctl --quiet --socket-path "$runtime/control" "$@"; }
# A failed native reconciliation must leave the policy process running, or the
# next activation inherits stopped services without a dispatcher to restart them.
manager_resume_after_failure() {
    [ -d "$runtime/services" ] || return 0
    dinit_control start --no-wait svc-nns-dispatcher 2>/dev/null || :
}
manager_prepare() {
    mkdir -p "$state/managers" "$runtime"; chmod 700 "$state/managers" "$runtime"
    prepare_changes
    publish_services
}
manager_preflight() {
    [ "$manager" = dinit ] || fail 'generation does not select dinit'
    "$sp/bin/dinit" --version >/dev/null || fail 'Dinit executable is unavailable'
    "$sp/bin/dinitctl" --version >/dev/null || fail 'Dinit control executable is unavailable'
    check_directory "$runtime/services"
    if [ -f "$state/manager-process" ] && [ "$previous" != '' ] && [ "$(manager_of "$previous")" = dinit ] && ! manager_running; then
        case "$(cat "$state/manager-process")" in
            *" $boot_id") fail 'Dinit exited unexpectedly this boot; refusing to create a duplicate owner';;
        esac
    fi
    [ -d "$generation/service-definitions/services" ] || fail 'missing Dinit definitions'
}
manager_activate() {
    if ! manager_running; then
        # The preflight rejects a same-boot manager crash with unknown children.
        rm -rf -- "$runtime/services"
    fi
    if manager_running; then
        dinit_control stop --force --ignore-unstarted svc-nns-dispatcher
        resume_pending=1
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
        resume_pending=
    else
        # A prior-boot socket is not evidence of a live manager.
        rm -f "$runtime/control"
        start_supervisor "$sp/bin/dinit" --system --container --services-dir "$runtime/services" --socket-path "$runtime/control" nns-runtime svc-nns-dispatcher
    fi
    attempts=0
    until dinit_control status svc-nns-dispatcher >/dev/null 2>&1; do
        attempts=$((attempts + 1)); [ "$attempts" -lt 10 ] || fail 'Dinit did not become available'; sleep 1
    done
    resume_pending=
    remove_obsolete_services
}
manager_stop() {
    if manager_running; then
        dinit_control shutdown
        wait_supervisor_exit
    else
        manager_preflight
    fi
}
