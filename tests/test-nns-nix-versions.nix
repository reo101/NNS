{ pkgs }:
let
  client = pkgs.writeShellScript "test-nix-client" ''
    if [ "$1" = --version ]; then
      printf 'nix (Nix) %s\n' "''${NNS_TEST_CLIENT_VERSION:-2.35.3}"
      exit 0
    fi
    test "$NIX_REMOTE" = daemon
    test "$*" = '--extra-experimental-features nix-command store info --json'
    if [ "''${NNS_TEST_DAEMON_FAILURE:-0}" = 1 ]; then
      echo 'test daemon protocol failure' >&2
      exit 17
    fi
    printf '{"version":"%s"}\n' "''${NNS_TEST_DAEMON_VERSION:-2.35.3}"
  '';
  check = "${pkgs.runtimeShell} ${../nix/check-nix-versions.sh} ${client} ${pkgs.jq}/bin/jq";
in
pkgs.runCommand "check-nns-nix-versions" { } ''
  ${check} > matching.log 2> matching.err
  grep -q 'Nix client=2.35.3' matching.log
  grep -q 'Nix daemon=2.35.3; daemon connection succeeded' matching.log
  test ! -s matching.err

  NNS_TEST_DAEMON_VERSION=2.34.9 ${check} > differing.log 2> differing.err
  grep -q 'Nix client=2.35.3' differing.log
  grep -q 'Nix daemon=2.34.9; daemon connection succeeded' differing.log
  grep -q 'warning: Nix versions differ' differing.err

  if NNS_TEST_DAEMON_FAILURE=1 ${check} > failure.log 2> failure.err; then
    echo 'daemon connection failure did not stop the check' >&2
    exit 1
  fi
  grep -q 'test daemon protocol failure' failure.err
  grep -q 'Nix client=2.35.3' failure.log
  if grep -q 'daemon connection succeeded' failure.log; then exit 1; fi
  touch "$out"
''
