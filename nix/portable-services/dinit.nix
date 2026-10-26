{ pkgs, services, ... }:
let
  inherit (pkgs) lib;
  renderService =
    name: service:
    pkgs.writeText "dinit-service-${name}" ''
      type = ${if service.type == "longrun" then "process" else "scripted"}
      command = ${service.command}
      working-dir = /
      start-timeout = ${builtins.toString (service.startTimeout or 30)}
      ${lib.optionalString (service.type == "oneshot") ''
        options = start-interruptible
        stop-timeout = 3
      ''}
      ${
        if service.type == "longrun" then
          ''
            restart = yes
            restart-limit-count = 0
          ''
        else
          "restart = no"
      }
      ${lib.optionalString (
        service.type == "longrun" && service.notificationFd != null
      ) "ready-notification = pipefd:${builtins.toString service.notificationFd}"}
      ${lib.concatMapStrings (dependency: "depends-ms = ${dependency}\n") service.dependencies}
    '';
  serviceFiles = builtins.mapAttrs renderService services;
  defaultFile = pkgs.writeText "dinit-service-default" ''
    type = internal
    ${lib.concatMapStrings (name: "depends-ms = ${name}\n") (builtins.attrNames services)}
  '';
in
pkgs.runCommand "dinit-services"
  {
    nativeBuildInputs = [ pkgs.buildPackages.dinit ];
  }
  ''
    mkdir -p "$out/services"
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: file: "ln -s ${lib.escapeShellArg file} \"$out/services/${name}\""
      ) serviceFiles
    )}
    ln -s ${lib.escapeShellArg defaultFile} "$out/services/default"
    dinit-check -d "$out/services" default
  ''
