{ buildFHSEnv, lib, sourceDirectory, logicalDirectory }:

# Keep cached absolute source paths inside a private namespace.
# The writable source is a reflink copy, not the retained baseline.
import ./rom-build-environment.nix {
  buildFHSEnv = arguments: buildFHSEnv (arguments // {
    name = "nns-cheetah-build-environment";
    extraBwrapArgs = (arguments.extraBwrapArgs or [ ]) ++ [
      (lib.escapeShellArgs [ "--bind" sourceDirectory logicalDirectory ])
    ];
  });
}
