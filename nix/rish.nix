# Shizuku-backed su/sudo/rish for launcher sessions.
#
# Delivery: the module zip carries these scripts plus the dex, and
# post-fs-data publishes them to /data/nix/var/nns/bin (already the first
# sessionPath entry; nix-enter prepends it for bare sessions). No store
# path is baked into the scripts, which keeps the module's
# allowedReferences empty - the dex rides along as a plain file instead.
#
# Application id resolution (the app that owns the shizuku_server):
#   1. NNS_APPLICATION_ID environment (per invocation)
#   2. /data/nix/etc/app-id (staged by post-fs-data from the module arg)
#   3. the baked @APP_ID@ default, substituted per host by module.nix
# The dex copy destination follows the caller instead: every terminal app
# stages its own read-only copy (RISH_HOME or $HOME, derived from the app
# id when unset).
{
  lib, pkgs, stdenvNoCC, unzip, fetchurl,
  # Baked fallback application id; module.nix substitutes the per-host one.
  appId ? "com.example.nns",
}:
let
  dex = stdenvNoCC.mkDerivation {
    name = "nns-rish-shizuku.dex";
    src = fetchurl {
      url = "https://github.com/RikkaApps/Shizuku/releases/download/v13.6.0/shizuku-v13.6.0.r1086.2650830c-release.apk";
      hash = "sha256-bic6sOmRxOebyLG7ubndc5zKwahxKlQaIUB4iGt7eQ8=";
    };
    nativeBuildInputs = [ unzip ];
    unpackPhase = ''
      unzip -j "$src" "assets/rish_shizuku.dex"
    '';
    dontBuild = true;
    installPhase = ''
      cp rish_shizuku.dex "$out"
      chmod 400 "$out"
    '';
  };

  rish = pkgs.writeText "nns-rish" /* sh */ ''
    #!/system/bin/sh
    # NNS rish: Shizuku-backed root for launcher sessions. Published by the
    # module to /data/nix/var/nns/bin; usable in any nix-enter session
    # without a NoD login.

    # The app that owns the shizuku_server: per-invocation env, staged
    # file, baked default. The dex copy destination follows the CALLER
    # instead (each terminal app keeps its own read-only copy).
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

    # Shizuku registers no servicemanager name (the binder handoff goes
    # via the REQUEST_BINDER broadcast) and /proc is hidepid=invisible
    # for this uid, so neither `service list` nor `pidof shizuku_server`
    # can confirm the server. Instead watch the loader's own behavior:
    # with arguments, run it buffered and treat a silent success as the
    # dead-server case (the loader answers the broadcast with a null
    # binder and exits 0 without a word). Bare `rish` stays an
    # interactive streaming session.

    # -Xgc:SS forces ART's semispace collector: the default
    # concurrent-copying collector creates a userfaultfd anon_inode, which
    # the nns_app domain may not self-create (ksud drops anon_inode
    # rules), killing app_process before its first log line.
    APPOPTS="-Xgc:SS"

    if [ "$#" -gt 0 ]; then
      /system/bin/mkdir -p "$HOME_DIR/tmp"
      tmp="$HOME_DIR/tmp/rish.$$"
      /system/bin/app_process $APPOPTS \
        -Djava.class.path="$DST" \
        /system/bin \
        --nice-name=rish \
        rikka.shizuku.shell.ShizukuShellLoader \
        "$@" >"$tmp" 2>&1
      rc=$?
      /system/bin/cat "$tmp"
      silent=0
      if [ "$rc" -eq 0 ] && [ ! -s "$tmp" ]; then
        silent=1
      fi
      /system/bin/rm -f "$tmp"
      if [ "$silent" -eq 1 ]; then
        echo "rish: no response from the shizuku server (it may not be running, or the output transport died)" >&2
        exit 1
      fi
      if [ "$rc" -ne 0 ]; then
        echo "rish: app_process exited $rc" >&2
      fi
      exit "$rc"
    fi

    /system/bin/app_process $APPOPTS \
      -Djava.class.path="$DST" \
      /system/bin \
      --nice-name=rish \
      rikka.shizuku.shell.ShizukuShellLoader
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "rish: app_process exited $rc" >&2
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
    # One-shot diagnostic for the rish chain: stages the dex exactly like
    # the wrapper, runs the loader raw against `-c id`, and reports the
    # outcome. No pidof preflight: /proc is hidepid=invisible for this
    # uid. The matching client/server log is pulled over adb afterwards.
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
    /system/bin/mkdir -p "$HOME_DIR/.rish"
    /system/bin/rm -f "$HOME_DIR/.rish/rish.dex"
    /system/bin/cp /data/nix/lib/rish.dex "$HOME_DIR/.rish/rish.dex"
    /system/bin/chmod 444 "$HOME_DIR/.rish/rish.dex"
    echo "dex: $(/system/bin/ls -la "$HOME_DIR/.rish/rish.dex" 2>&1)"
    RISH_APPLICATION_ID="$APP_ID" \
      /system/bin/app_process -Xgc:SS \
      -Djava.class.path="$HOME_DIR/.rish/rish.dex" \
      /system/bin --nice-name=rishprobe rikka.shizuku.shell.ShizukuShellLoader -c id
    echo "probe_rc=$? (the matching client/server log is pulled over adb after running)"
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
