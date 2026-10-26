# shellcheck shell=sh
# shellcheck disable=SC2154 # Globals are shared with the parent runtime.

# A failed update must not leave the dispatcher paused. A paused dispatcher hides
# native state from the next activation and from operator control tools, so the
# retry starts from an inconsistent tree. Restore both policy processes instead.
manager_resume_after_failure() {
    [ -d "$runtime/scan" ] || return 0
    "$sp/bin/s6-svc" -U "$runtime/scan/svc-nns-dispatcher" 2>/dev/null || :
    "$sp/bin/s6-svc" -U "$runtime/scan/s6rc-oneshot-runner" 2>/dev/null || :
}
manager_prepare() {
    mkdir -p "$state/managers" "$runtime"; chmod 700 "$state/managers" "$runtime"
    prepare_changes
    publish_services
}
manager_preflight() {
    [ "$(cat "$generation/service-manager" 2>/dev/null)" = s6-rc ] || fail 'generation does not select s6-rc'
    [ -d "$generation/service-definitions/source" ] || fail 'missing s6-rc source definitions'
    check_directory "$runtime/scan"
    if [ -e "$runtime/live" ] || [ -L "$runtime/live" ]; then
        live_directory=$(readlink -f "$runtime/live") || fail 'cannot resolve s6 live state'
        runtime_directory=$(readlink -f "$runtime") || fail 'cannot resolve s6 runtime'
        case $live_directory in "$runtime_directory"/*) ;; *) fail 's6 live state escapes its runtime directory';; esac
        check_directory "$live_directory"
    fi
    check_directory "$state/service-databases"
    mkdir -p "$state/service-databases"
    check_directory "$state/service-databases"

    definitions=$(readlink -f "$generation/service-definitions") || fail 'cannot resolve service definitions'
    database_name=${definitions##*/}
    database=$state/service-databases/db-$database_name
    if [ -e "$database" ] || [ -L "$database" ]; then
        [ -d "$database" ] && [ ! -L "$database" ] || fail "invalid compiled database: $database"
        check_directory "$database"
        "$sp/bin/s6-rc-db" -c "$database" check || fail "invalid compiled database: $database"
        return
    fi

    temporary=$(mktemp -d "$state/service-databases/.compile.XXXXXXXX") || fail 'cannot create database staging directory'
    check_directory "$temporary"
    if ! "$sp/bin/s6-rc-compile" "$temporary/database" "$generation/service-definitions/source"; then
        rm -rf -- "$temporary"
        fail 's6-rc-compile failed'
    fi
    "$sp/bin/s6-rc-db" -c "$temporary/database" check || {
        rm -rf -- "$temporary"
        fail 'compiled s6-rc database failed validation'
    }
    if [ -e "$database" ] || [ -L "$database" ]; then
        rm -rf -- "$temporary"
        fail "compiled database appeared during staging: $database"
    fi
    mv "$temporary/database" "$database" || {
        rm -rf -- "$temporary"
        fail 'cannot publish compiled s6-rc database'
    }
    rmdir "$temporary" || fail 'cannot remove database staging directory'
}

manager_activate() {
    definitions=$(readlink -f "$generation/service-definitions") || fail 'cannot resolve service definitions'
    database=$state/service-databases/db-${definitions##*/}
    [ -d "$database" ] && [ ! -L "$database" ] || fail "compiled database is missing: $database"
    check_directory "$database"
    check_directory "$state/managers"
    mkdir -p "$state/managers"
    check_directory "$state/managers"
    check_directory "$runtime"
    mkdir -p "$runtime"
    check_directory "$runtime"

    if ! manager_running || [ ! -d "$runtime/live" ]; then
        manager_stop || fail 'cannot clean stale s6-rc runtime'
        invalidate_oneshots
        mkdir -p "$runtime/scan"
        check_directory "$runtime/scan"
        start_supervisor "$sp/bin/s6-svscan" "$runtime/scan"
        attempts=0
        until "$sp/bin/s6-svscanctl" -a "$runtime/scan" 2>/dev/null; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 50 ] || fail 's6 scanner did not become available'
            sleep 0.1
        done
        "$sp/bin/s6-rc-init" -c "$database" -l "$runtime/live" "$runtime/scan" || fail 's6-rc initialization failed'
        "$sp/bin/s6-rc" -l "$runtime/live" -u change svc-nns-dispatcher || fail 'cannot start NNS dispatcher'
        "$sp/bin/s6-svc" -U "$runtime/scan/svc-nns-dispatcher" || fail 'cannot enable NNS dispatcher'
        remove_obsolete_services
        return
    fi

    "$sp/bin/s6-svc" -wD -T5000 -POK "$runtime/scan/svc-nns-dispatcher" || fail 'cannot pause NNS dispatcher'
    resume_pending=1
    "$sp/bin/s6-svc" -wD -T5000 -POK "$runtime/scan/s6rc-oneshot-runner" || fail 'cannot pause s6-rc oneshot runner'
    "$sp/bin/s6-svc" -wU -T5000 -U "$runtime/scan/s6rc-oneshot-runner" || fail 'cannot restart s6-rc oneshot runner'

    invalidate_oneshots
    # Keep startup asynchronous, including a longrun becoming a failed finite
    # action or a running service gaining a new finite prerequisite. Otherwise
    # the updater restores its old up-state and waits for the new action itself.
    cat "$updates/finite" "$updates/changed" > "$updates/reset"
    set --
    while IFS= read -r service_id; do
        if "$sp/bin/s6-rc-db" -l "$runtime/live" type "$service_id" >/dev/null 2>&1; then
            set -- "$@" "$service_id"
        fi
    done < "$updates/reset"
    if [ "$#" -gt 0 ]; then
        "$sp/bin/s6-rc" -l "$runtime/live" -d change "$@" || fail 'cannot stop changed services and reset finite state'
    fi

    # The updater restores previously-up services. Stop the new unlock closure
    # first, or it can bypass the dispatcher's phase selection during an update.
    if [ "$(/system/bin/getprop sys.user.0.ce_available)" != true ]; then
        set --
        for service_directory in "$state"/services/*; do
            [ -d "$service_directory" ] || continue
            service_id=svc-${service_directory##*/}
            if grep -Fxq "$service_id" "$generation/all-services" &&
                ! grep -Fxq "$service_id" "$generation/boot-services" &&
                "$sp/bin/s6-rc-db" -l "$runtime/live" type "$service_id" >/dev/null 2>&1; then
                set -- "$@" "$service_id"
            fi
        done
        if [ "$#" -gt 0 ]; then
            "$sp/bin/s6-rc" -l "$runtime/live" -d change "$@" || fail 'cannot defer unlock-gated services'
        fi
    fi

    # A dispatcher child can still hold the database lock during a transition.
    # Wait for it instead of failing the update on a transient lock.
    if "$sp/bin/s6-rc-update" -b -l "$runtime/live" "$database"; then
        update_status=0
    else
        update_status=$?
    fi
    [ "$update_status" -eq 0 ] || fail "s6-rc database update failed with status $update_status"

    "$sp/bin/s6-svc" -wU -T5000 -U "$runtime/scan/s6rc-oneshot-runner" || fail 'cannot re-enable s6-rc oneshot runner'
    "$sp/bin/s6-svc" -U "$runtime/scan/svc-nns-dispatcher" || fail 'cannot re-enable NNS dispatcher'
    resume_pending=
    remove_obsolete_services
}

manager_stop() {
    [ ! -L "$runtime" ] || fail 's6-rc runtime is a symlink'
    if [ ! -d "$runtime/scan" ]; then
        if [ -d "$runtime" ]; then
            manager_running && fail 'cannot remove s6-rc runtime while its supervisor is running'
            check_directory "$runtime"
            rm -rf -- "$runtime"
        fi
        return 0
    fi

    if manager_running && [ -d "$runtime/live" ]; then
        "$sp/bin/s6-svc" -wD -T5000 -POK "$runtime/scan/svc-nns-dispatcher" || fail 'cannot pause NNS dispatcher for shutdown'
        "$sp/bin/s6-svc" -wD -T5000 -POK "$runtime/scan/s6rc-oneshot-runner" || fail 'cannot pause s6-rc oneshot runner for shutdown'
        "$sp/bin/s6-svc" -wU -T5000 -U "$runtime/scan/s6rc-oneshot-runner" || fail 'cannot restart s6-rc oneshot runner for shutdown'
        "$sp/bin/s6-rc" -l "$runtime/live" -da change || fail 's6-rc graceful shutdown failed'
    else
        for service_directory in "$runtime"/scan/*; do
            [ -d "$service_directory" ] || continue
            if "$sp/bin/s6-svok" "$service_directory"; then
                "$sp/bin/s6-svc" -POK "$service_directory" || fail "cannot cancel supervised action: ${service_directory##*/}"
            fi
        done
        for service_directory in "$runtime"/scan/*; do
            [ -d "$service_directory" ] || continue
            if "$sp/bin/s6-svok" "$service_directory"; then
                "$sp/bin/s6-svc" -wD -T5000 -dx "$service_directory" || fail "cannot stop supervised service: ${service_directory##*/}"
            fi
        done
    fi

    if manager_running; then
        "$sp/bin/s6-svscanctl" -t "$runtime/scan" || fail 'cannot terminate s6 supervision tree'
    fi
    wait_supervisor_exit || fail 's6 supervision tree did not exit'
    attempt=0
    while [ "$attempt" -lt 5 ]; do
        attempt=$((attempt + 1))
        running=false
        for service_directory in "$runtime"/scan/*; do
            [ -d "$service_directory" ] || continue
            if "$sp/bin/s6-svok" "$service_directory" >/dev/null 2>&1; then running=true; fi
        done
        [ "$running" = false ] && break
        sleep 1
    done
    [ "$running" = false ] || fail 's6 supervisors remain active; preserving runtime tree'
    rm -rf -- "$runtime"
}
