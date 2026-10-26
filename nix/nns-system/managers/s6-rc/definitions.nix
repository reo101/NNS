# s6-rc owns dependency ordering and finite state. The compiled database stays
# deferred: preflight compiles it on the target with the target's compiler.
{
  pkgs,
  lib,
  services,
  modules,
  ...
}:
let
  portable = import ../../../portable-services {
    inherit pkgs modules;
    manager = "s6-rc";
    compileS6Database = false;
  };
in
pkgs.runCommand "nns-service-definitions-s6-rc" { } ''
  cp -r ${portable.package}/. "$out/"
  ${lib.concatMapStrings (
    name:
    lib.optionalString (services.${name}.type == "longrun") ''
      chmod u+w "$out/source/svc-${name}"
      printf '10000\n' > "$out/source/svc-${name}/timeout-down"
    ''
  ) (builtins.attrNames services)}
''
