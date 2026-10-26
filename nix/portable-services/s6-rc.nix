{
  pkgs,
  services,
  compileDatabase ? true,
}:
let
  inherit (pkgs) lib;
  renderService = name: service: ''
    mkdir -p "$out/source/${name}/dependencies.d"
    printf '%s\n' ${lib.escapeShellArg service.type} > "$out/source/${name}/type"
    printf '%s\n' ${builtins.toString (service.startTimeout * 1000)} > "$out/source/${name}/timeout-up"
    ${
      if service.type == "longrun" then
        ''
          ln -s ${service.command} "$out/source/${name}/run"
          ${lib.optionalString (service.notificationFd != null) ''
            printf '%s\n' ${builtins.toString service.notificationFd} > "$out/source/${name}/notification-fd"
          ''}
        ''
      else
        ''
          printf '%s\n' ${service.command} > "$out/source/${name}/up"
          printf '%s\n' ${lib.getExe' pkgs.coreutils "true"} > "$out/source/${name}/down"
        ''
    }
    ${lib.concatMapStringsSep "\n" (dependency: ''
      touch "$out/source/${name}/dependencies.d/${dependency}"
    '') service.dependencies}
  '';
in
assert
  !compileDatabase
  ||
    lib.assertMsg (pkgs.stdenv.buildPlatform.config == pkgs.stdenv.hostPlatform.config)
      "portable services: s6-rc database cross compilation is not implemented; use a native package set";
pkgs.runCommand "s6-rc-services"
  {
    nativeBuildInputs = lib.optionals compileDatabase [ pkgs.s6-rc ];
  }
  ''
    mkdir -p "$out/source/default/contents.d"
    printf 'bundle\n' > "$out/source/default/type"
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList renderService services)}
    ${lib.concatMapStringsSep "\n" (name: ''touch "$out/source/default/contents.d/${name}"'') (
      builtins.attrNames services
    )}
    ${lib.optionalString compileDatabase ''s6-rc-compile "$out/compiled" "$out/source"''}
  ''
