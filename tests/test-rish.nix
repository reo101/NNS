{ pkgs }:
let
  scripts = pkgs.callPackage ../nix/rish.nix { };
in
pkgs.runCommand "check-nns-rish" { } ''
  mkdir -p android/bin home
  for command in mkdir rm cp chmod cat mktemp; do
    ln -s ${pkgs.coreutils}/bin/$command android/bin/$command
  done
  cat > android/bin/app_process <<'EOF'
  #!${pkgs.runtimeShell}
  if [ "''${NNS_TEST_SERVER_UNAVAILABLE:-}" = 1 ]; then
    printf '%s\n' 'Server is not running' >&2
    exit 1
  fi
  if [ "''${NNS_TEST_SILENT_APP_PROCESS:-}" = 1 ]; then
    exit 0
  fi
  test -n "$BOOTCLASSPATH" || exit 9
  test "$CLASSPATH" = "$HOME/.rish/rish.dex" || exit 9
  while [ "$1" != rikka.shizuku.shell.ShizukuShellLoader ]; do
    case "$1" in -Xgc:*|-Djava.class.path=*) exit 9 ;; esac
    shift
  done
  shift
  ${pkgs.runtimeShell} "$@"
  status=$?
  printf 'complete\n' > "$NNS_RISH_COMPLETION_FILE"
  exit "$status"
  EOF
  chmod +x android/bin/app_process
  substitute ${scripts}/bin/rish rish \
    --replace-fail /system/bin "$PWD/android/bin" \
    --replace-fail /data/nix/lib/rish.dex ${scripts}/lib/rish.dex \
    --replace-fail 'export LD_PRELOAD=/data/nix/lib/libnns-dns.so' 'unset LD_PRELOAD'
  export HOME="$PWD/home" NNS_APPLICATION_ID=com.example.nns BOOTCLASSPATH=/system/framework/test.jar

  ${pkgs.runtimeShell} rish -c true >stdout 2>stderr
  test ! -s stdout
  test ! -s stderr

  if ${pkgs.runtimeShell} rish -c 'exit 7' >stdout 2>stderr; then
    exit 1
  else
    test "$?" = 7
  fi
  test ! -s stdout

  ${pkgs.runtimeShell} rish -c 'printf output; printf diagnostic >&2' >stdout 2>stderr
  test "$(cat stdout)" = output
  test "$(cat stderr)" = diagnostic

  ${pkgs.runtimeShell} rish -c 'printf output-without-newline' >stdout 2>stderr
  test "$(wc -c <stdout)" = 22
  test "$(cat stdout)" = output-without-newline
  test ! -s stderr

  ${pkgs.runtimeShell} rish -c 'exec sh -c "printf exec-output; exit 0"' >stdout 2>stderr
  test "$(cat stdout)" = exec-output
  test ! -s stderr

  if NNS_TEST_SILENT_APP_PROCESS=1 ${pkgs.runtimeShell} rish -c true >stdout 2>stderr; then
    exit 1
  else
    test "$?" = 1
  fi
  test ! -s stdout
  grep -Fx 'rish: command completion not verified' stderr

  if NNS_TEST_SERVER_UNAVAILABLE=1 ${pkgs.runtimeShell} rish -c true >stdout 2>stderr; then
    exit 1
  else
    test "$?" = 1
  fi
  grep -Fx 'Server is not running' stderr

  printf '%s\n' 'printf interactive' | ${pkgs.runtimeShell} rish >stdout 2>stderr
  test "$(cat stdout)" = interactive
  test ! -s stderr

  mkfifo resume
  ${pkgs.runtimeShell} rish -c "printf early; read -r response < '$PWD/resume'" >stream-output 2>stderr &
  client=$!
  for attempt in $(seq 1 100); do
    test ! -s stream-output || break
    sleep 0.01
  done
  test "$(cat stream-output)" = early
  kill -0 "$client"
  printf 'resume\n' > resume
  wait "$client"
  test ! -s stderr
  test "$(find home/.rish -mindepth 1 -maxdepth 1 -type d | wc -l)" = 0
  touch "$out"
''
