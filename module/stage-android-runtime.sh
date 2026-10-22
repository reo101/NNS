#!/system/bin/sh
# Publish only the Android classpaths needed by app_process clients.
set -eu
[ "$(id -u)" = 0 ] || exit 1
source=${1:-/data/system/environ/classpath}
directory=${2:-/data/nix/etc}
[ -r "$source" ] || { echo 'nns: Android classpaths are not available yet' >&2; exit 0; }
[ ! -L "$source" ] && [ -f "$source" ] || exit 1
case $(stat -c %u "$source") in 0|1000) ;; *) exit 1 ;; esac
[ ! -L "$directory" ] && [ -d "$directory" ] || exit 1
[ "$(stat -c %u "$directory")" = 0 ] || exit 1
permissions=$(stat -c %a "$directory")
[ "$((8#$permissions & 8#22))" = 0 ] || exit 1
umask 077
temporary=$(mktemp "$directory/.android-runtime.XXXXXXXX")
trap 'rm -f "$temporary"' EXIT
boot=false
while read -r instruction name value remainder; do
    case "$instruction:$name" in
        export:BOOTCLASSPATH|export:DEX2OATBOOTCLASSPATH)
            [ -n "$value" ] && [ -z "$remainder" ] || exit 1
            case "$value" in *[!a-zA-Z0-9_./:@+-]*) exit 1 ;; esac
            printf "export %s='%s'\n" "$name" "$value" >> "$temporary"
            [ "$name" != BOOTCLASSPATH ] || boot=true
            ;;
    esac
done < "$source"
[ "$boot" = true ] || exit 1
chmod 644 "$temporary"
mv -f "$temporary" "$directory/android-runtime.env"
