# shellcheck shell=sh
# shellcheck disable=SC2154 # Globals are shared with the dispatcher.

manager_apply() {
    selection=$1
    set --
    while IFS= read -r name; do [ -z "$name" ] || set -- "$@" "$name"; done < "$selection"
    if [ "$#" -gt 0 ]; then
        s6-rc -b -l "$state/managers/s6-rc/live" -u change "$@" || successful=false
    fi
}
manager_complete() {
    s6-svc -O "$state/managers/s6-rc/scan/svc-nns-dispatcher"
    exit 0
}
