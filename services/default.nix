# Shipped service features. Each file is a plain Nix-on-Droid module that
# plugs into the generic nns.services machinery: a service definition under
# nns.services.services (rendered by the shared run-script generator) plus
# state materialization through nns.services.extraActivation.
#
# This module declares the flake output so feature files can contribute
# entries without touching outputs.nix; consumers import them from
# inputs.<nns>.nixOnDroidModules.
{ lib, ... }:
{
  options.flake.nixOnDroidModules = lib.mkOption {
    type = with lib.types; lazyAttrsOf raw;
    description = ''
      Nix-on-Droid modules exported by the NNS flake: the core module
      (nns) and the opt-in service features.
    '';
  };

  config.flake.nixOnDroidModules."nns-sshd" = import ./sshd.nix;
}
