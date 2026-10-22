# Shizuku-backed su/sudo/rish for launcher sessions.
#
# Delivery: the module zip carries these scripts plus the dex, and
# post-fs-data publishes them to /data/nix/var/nns/bin (already the first
# sessionPath entry; nix-enter prepends it for bare sessions). No store
# path is baked into the scripts, which keeps the module's
# allowedReferences empty - the dex rides along as a plain file instead.
#
# Fallback client application id resolution:
#   1. NNS_APPLICATION_ID environment (per invocation)
#   2. /data/nix/etc/app-id (staged by post-fs-data from the module arg)
#   3. the baked @APP_ID@ default, substituted per host by module.nix
# The dex copy destination follows the caller instead: every terminal app
# stages its own read-only copy (RISH_HOME or $HOME, derived from the app
# id when unset).
{
  lib, pkgs, stdenvNoCC,
  # Baked fallback application id; module.nix substitutes the per-host one.
  appId ? "com.example.nns",
}:
let
  dex = pkgs.callPackage ./rish-client.nix { };

  rish = pkgs.writeText "nns-rish" /* sh */ ''
    #!/system/bin/sh
    # NNS rish: Shizuku-backed root for launcher sessions. Published by the
    # module to /data/nix/var/nns/bin; usable in any nix-enter session
    # without a NoD login.

    # The fallback client application id comes from the environment, staged
    # file, or baked default. Each caller keeps its own read-only dex copy.
    APP_ID="$NNS_APPLICATION_ID"
    if [ -z "$APP_ID" ]; then
      APP_ID="$(cat /data/nix/etc/app-id 2>/dev/null)"
    fi
    if [ -z "$APP_ID" ]; then
      APP_ID='@APP_ID@'
    fi

    HOME_DIR="$RISH_HOME"
    if [ -z "$HOME_DIR" ]; then
      HOME_DIR="$HOME"
    fi
    if [ -z "$HOME_DIR" ] || [ "$HOME_DIR" = "/" ]; then
      HOME_DIR="/data/data/$APP_ID/files/home"
    fi

    # app_process refuses dex it could write (Android 14+) and fails to
    # open store paths inside the launcher namespace: an app-owned
    # read-only copy is the proven shape (launcher sessions and root
    # chains alike).
    DST="$HOME_DIR/.rish/rish.dex"
    /system/bin/mkdir -p "$HOME_DIR/.rish"
    /system/bin/rm -f "$DST"
    if ! /system/bin/cp /data/nix/lib/rish.dex "$DST"; then
      echo "rish: cannot stage dex to $DST (set RISH_HOME or HOME)" >&2
      exit 1
    fi
    /system/bin/chmod 444 "$DST"

    export RISH_APPLICATION_ID="$APP_ID"
    # The NNS bionic resolver shim rides along into app_process (same
    # preload every login session uses).
    export LD_PRELOAD=/data/nix/lib/libnns-dns.so
    export NNS_RISH_PROPERTY_INFO_SHIM=1
    # Restrict PATH to root-only binaries.
    export PATH="/bin:/system/bin"

    # SSH does not inherit Android's Java environment. The root boot service
    # publishes the platform-derived classpaths without exposing /data/system.
    if [ -z "$BOOTCLASSPATH" ] && [ -r /data/nix/etc/android-runtime.env ]; then
      . /data/nix/etc/android-runtime.env
    fi
    if [ -z "$BOOTCLASSPATH" ]; then
      echo 'rish: Android boot classpath is unavailable' >&2
      exit 1
    fi
    export ANDROID_ROOT="''${ANDROID_ROOT:-/system}"
    export ANDROID_DATA="''${ANDROID_DATA:-/data}"
    export ANDROID_ART_ROOT="''${ANDROID_ART_ROOT:-/apex/com.android.art}"
    export ANDROID_I18N_ROOT="''${ANDROID_I18N_ROOT:-/apex/com.android.i18n}"
    export ANDROID_TZDATA_ROOT="''${ANDROID_TZDATA_ROOT:-/apex/com.android.tzdata}"
    export CLASSPATH="$DST"

    # app_process can exit zero before Java starts. The client acknowledges
    # orderly shutdown in a caller-private file, without buffering its streams.
    work=$(/system/bin/mktemp -d "$HOME_DIR/.rish/client.XXXXXXXX") || exit 1
    trap '/system/bin/rm -rf "$work"' EXIT
    export NNS_RISH_COMPLETION_FILE="$work/completion"
    /system/bin/app_process /system/bin --nice-name=rish \
      rikka.shizuku.shell.ShizukuShellLoader "$@"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$(/system/bin/cat "$NNS_RISH_COMPLETION_FILE" 2>/dev/null)" != complete ]; then
      echo 'rish: command completion not verified' >&2
      exit 1
    fi
    exit "$rc"
  '';

  su = pkgs.writeText "nns-su" /* sh */ ''
    #!/system/bin/sh
    # Forward everything: Android's `su -c 'cmd'` maps onto rish's own
    # `-c cmd` interface. Dropping "$@" here made bare rish read EOF'd
    # stdin and exit 0 silently - the perfect no-op.
    exec /data/nix/var/nns/bin/rish "$@"
  '';

  sudo = pkgs.writeText "nns-sudo" /* sh */ ''
    #!/system/bin/sh
    exec /data/nix/var/nns/bin/rish -c "$*"
  '';

  rishProbe = pkgs.writeText "nns-rish-probe" /* sh */ ''
    #!/system/bin/sh
    # Use the same loader, permission checks, and completion acknowledgement.
    printf 'caller: '
    /system/bin/id
    exec /data/nix/var/nns/bin/rish -c id
  '';
in
stdenvNoCC.mkDerivation {
  name = "nns-rish-scripts";
  dontUnpack = true;
  dontFixup = true; # Keep the Android shebangs untouched.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/lib"
    install -m 755 ${rish} "$out/bin/rish"
    install -m 755 ${su} "$out/bin/su"
    install -m 755 ${sudo} "$out/bin/sudo"
    install -m 755 ${rishProbe} "$out/bin/rish-probe"
    install -m 444 ${dex} "$out/lib/rish.dex"
    runHook postInstall
  '';
  passthru = { inherit dex appId; };
}
