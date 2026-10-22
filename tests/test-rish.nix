{ pkgs }:
let
  scripts = pkgs.callPackage ../nix/rish.nix { };
in
pkgs.runCommand "check-nns-rish" { } ''
  mkdir -p android/bin home
  for command in mkdir rm cp chmod cat; do
    ln -s ${pkgs.coreutils}/bin/$command android/bin/$command
  done
  cat > android/bin/app_process <<'EOF'
  #!${pkgs.runtimeShell}
  if [ "''${NNS_TEST_SERVER_UNAVAILABLE:-}" = 1 ]; then
    printf '%s\n' 'Server is not running' >&2
    exit 1
  fi
  while [ "$1" != rikka.shizuku.shell.ShizukuShellLoader ]; do shift; done
  shift
  exec ${pkgs.runtimeShell} "$@"
  EOF
  chmod +x android/bin/app_process
  substitute ${scripts}/bin/rish rish \
    --replace-fail /system/bin "$PWD/android/bin" \
    --replace-fail /data/nix/lib/rish.dex ${scripts}/lib/rish.dex \
    --replace-fail 'export LD_PRELOAD=/data/nix/lib/libnns-dns.so' 'unset LD_PRELOAD'
  export HOME="$PWD/home" NNS_APPLICATION_ID=com.example.nns

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

  if NNS_TEST_SERVER_UNAVAILABLE=1 ${pkgs.runtimeShell} rish -c true >stdout 2>stderr; then
    exit 1
  else
    test "$?" = 1
  fi
  grep -Fx 'Server is not running' stderr

  printf '%s\n' 'printf interactive' | ${pkgs.runtimeShell} rish >stdout 2>stderr
  test "$(cat stdout)" = interactive
  test ! -s stderr
  touch "$out"
''
