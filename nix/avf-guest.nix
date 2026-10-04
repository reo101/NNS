{ lib, nixpkgs }:
# The NNS NixOS AVF guest payload: a store-only root image, kernel+initrd
# for direct loading by the AVF client, and the vm_config.json it reads.
# Evaluated natively for aarch64 (the image builder and the kernel are
# guest-arch derivations), so building needs an aarch64 builder or cache.
(nixpkgs.lib.nixosSystem {
  system = "aarch64-linux";
  modules = [ (import ../integrations/avf/guest-module.nix) ];
}).config.system.build.nnsAvfPayload
