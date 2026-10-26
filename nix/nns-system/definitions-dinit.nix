# Dinit owns dependency ordering and finite state. The internal service marks
# the container root, which Dinit requires for --container supervision.
{
  pkgs,
  modules,
  ...
}:
let
  portable = import ../service-backends {
    inherit pkgs modules;
    backend = "dinit";
  };
in
pkgs.runCommand "nns-service-definitions-dinit" { } ''
  cp -r ${portable.package}/. "$out/"
  chmod u+w "$out/services"
  printf 'type = internal\n' > "$out/services/nns-runtime"
''
