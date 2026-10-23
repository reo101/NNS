#!/bin/sh
# Shared only for POSIX descriptor inheritance and detached process creation.
set -eu
umask 077
operation=$1
shift
case "$operation" in
    lock)
        lock=$1
        shift
        # The child never inherits the lock descriptor, including on supervisor spawn.
        exec flock --close "$lock" "$@"
        ;;
    spawn)
        log=$1
        pidfile=$2
        shift 2
        nohup "$@" </dev/null >>"$log" 2>&1 &
        printf '%s\n' "$!" > "$pidfile"
        ;;
    *) printf 'unknown process boundary: %s\n' "$operation" >&2; exit 2 ;;
esac
