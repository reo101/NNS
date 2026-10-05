{ nixpkgs }:
{
  system,
  modules ? [ ],
  specialArgs ? { },
  pkgs ? import nixpkgs { inherit system; },
}:
let
  evaluated = pkgs.lib.evalModules {
    class = "nns";
    specialArgs = specialArgs // {
      inherit pkgs;
    };
    modules = [ ./nns-system/module.nix ] ++ modules;
  };
  failures = map (item: item.message) (
    builtins.filter (item: !item.assertion) evaluated.config.assertions
  );
in
assert pkgs.lib.assertMsg (failures == [ ]) (builtins.concatStringsSep "\n" failures);
evaluated
