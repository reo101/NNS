{ pkgs }:
let
  backends = [
    "runit"
    "s6-rc"
    "dinit"
  ];
  variants = [
    "base"
    "update"
    "typechange"
    "remove"
    "gated"
    "finite-failure"
  ];
  evaluate =
    packages: modules:
    import ../../nix/nns-system.nix { nixpkgs = packages.path; } {
      pkgs = packages;
      system = packages.stdenv.hostPlatform.system;
      inherit modules;
    };
  packages = builtins.concatMap (
    backend: map (variant: import ./fixture.nix { inherit pkgs backend variant; }) variants
  ) backends;
  cross = pkgs.pkgsCross.aarch64-multiplatform;
  crossGenerations = map (
    backend:
    (evaluate cross [ { system.serviceManager = backend; } ]).config.system.build.toplevel.drvPath
  ) backends;
  rejects =
    module: !(builtins.tryEval (evaluate pkgs [ module ]).config.system.build.toplevel.drvPath).success;
in
assert (evaluate pkgs [ ]).config.system.serviceManager == "runit";
assert rejects { system.serviceManager = "nosh"; };
assert builtins.all (
  backend:
  rejects {
    system.serviceManager = backend;
    services.runit.legacy.process.argv = [ "/system/bin/true" ];
  }
) backends;
assert builtins.all
  (
    backend:
    rejects {
      system.serviceManager = backend;
      system.services.nns-dispatcher.process.argv = [ "/system/bin/true" ];
    }
  )
  [
    "s6-rc"
    "dinit"
  ];
assert builtins.all (
  backend:
  rejects {
    system.serviceManager = backend;
    system.services.invalid = {
      process.argv = [ "/system/bin/true" ];
      nns.after = [ "missing" ];
    };
  }
) backends;
builtins.deepSeq (map (package: package.drvPath) packages ++ crossGenerations) true
