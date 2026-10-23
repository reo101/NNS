{ pkgs, backend }:
let
  inherit (pkgs) lib;
  capture = pkgs.writeText "portable-service-capture.py" ''
    import json, os, pathlib, sys
    arguments = sys.argv[1:]
    source = pathlib.Path(arguments[arguments.index("--configuration") + 1])
    result = {
        "arguments": arguments,
        "configuration": source.read_text(),
        "literal": os.environ["PORTABLE_LITERAL"],
        "empty": os.environ["PORTABLE_EMPTY"],
        "unset": "PORTABLE_UNSET" not in os.environ,
        "uid_environment": os.environ["UID"],
    }
    (pathlib.Path(os.environ["BACKEND_TEST_DIRECTORY"]) / "environment.json").write_text(json.dumps(result))
  '';
  finite =
    filename:
    pkgs.writeShellScript "portable-test-${filename}" ''
      printf 'run\n' >> "$BACKEND_TEST_DIRECTORY/${filename}"
    '';
in
import ../../nix/service-backends {
  inherit pkgs backend;
  configurationDirectory = "/tmp/portable-service-backend-configuration";
  modules = [
    {
      services = {
        prepare = {
          lifecycle.type = "oneshot";
          process.argv = [
            (pkgs.writeShellScript "portable-test-prepare" ''
              printf 'attempt\n' >> "$BACKEND_TEST_DIRECTORY/attempts"
              test -f "$BACKEND_TEST_DIRECTORY/release"
            '')
          ];
        };
        consumer = {
          lifecycle.requires = [ "prepare" ];
          process.argv = [
            (pkgs.writeShellScript "portable-test-consumer" ''
              printf 'started\n' >> "$BACKEND_TEST_DIRECTORY/consumer"
              exec ${lib.getExe' pkgs.coreutils "sleep"} 3600
            '')
          ];
        };
        independent = {
          lifecycle.type = "oneshot";
          process.argv = [ (finite "independent") ];
        };
        literal-executable = {
          lifecycle.type = "oneshot";
          process.argv = [
            (pkgs.writeShellScript "portable-service=literal" ''
              printf 'executed\n' > "$BACKEND_TEST_DIRECTORY/literal-executable"
            '')
          ];
        };
        environment = { config, ... }: {
          lifecycle.type = "oneshot";
          configData."nested/settings.conf".text = "generated configuration\n";
          configData."reference.conf".source = ./configuration.conf;
          configData.disabled = {
            enable = false;
            text = "not generated";
          };
          process = {
            argv = lib.mkMerge [
              [
                (lib.getExe pkgs.python3)
                capture
                "--configuration"
                config.configData."nested/settings.conf".path
              ]
              (lib.mkAfter [ "tail argument" ])
            ];
            flags = [
              { "--entry" = "first value"; }
              { "--entry" = "second \"quote\""; }
            ];
            environment = {
              PORTABLE_LITERAL = "spaces ' \" $HOME $(not-a-command)\nsecond line";
              PORTABLE_EMPTY = "";
              PORTABLE_UNSET = null;
              UID = "declarative value";
            };
          };
        };
        ownership.services.worker = {
          lifecycle.type = "oneshot";
          process.argv = [ (finite "nested-worker") ];
        };
        ownership-worker = {
          lifecycle.type = "oneshot";
          process.argv = [ (finite "flat-worker") ];
        };
        readiness = {
          notificationProtocol.s6 = true;
          lifecycle.notificationFd = 5;
          process.argv = [
            (pkgs.writeShellScript "portable-test-ready" ''
              touch "$BACKEND_TEST_DIRECTORY/starting"
              until test -e "$BACKEND_TEST_DIRECTORY/ready"; do
                ${lib.getExe' pkgs.coreutils "sleep"} 0.02
              done
              printf '\n' >&5
              exec 5>&-
              exec ${lib.getExe' pkgs.coreutils "sleep"} 3600
            '')
          ];
        };
        ready-consumer = {
          lifecycle = {
            type = "oneshot";
            requires = [ "readiness" ];
          };
          process.argv = [ (finite "ready-consumer") ];
        };
        timeout = {
          notificationProtocol.s6 = true;
          lifecycle.startTimeout = 1;
          process.argv = [
            (pkgs.writeShellScript "portable-test-timeout" ''
              touch "$BACKEND_TEST_DIRECTORY/timeout-starting"
              exec ${lib.getExe' pkgs.coreutils "sleep"} 2
            '')
          ];
        };
        timeout-consumer = {
          lifecycle = {
            type = "oneshot";
            requires = [ "timeout" ];
          };
          process.argv = [ (finite "timeout-consumer") ];
        };
        restart = {
          process.argv = [
            (pkgs.writeShellScript "portable-test-restart" ''
              count=0
              if test -e "$BACKEND_TEST_DIRECTORY/restarts"; then
                count=$(cat "$BACKEND_TEST_DIRECTORY/restarts")
              fi
              count=$((count + 1))
              printf '%s\n' "$count" > "$BACKEND_TEST_DIRECTORY/restarts"
              if test "$count" -lt 6; then exit "$((count % 2))"; fi
              exec ${lib.getExe' pkgs.coreutils "sleep"} 3600
            '')
          ];
        };
      };
    }
  ];
}
