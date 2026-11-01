{ buildFHSEnv, fetchurl, runCommand, runtimeGroupFile }:

let
  capabilitySource = fetchurl {
    url = "https://raw.githubusercontent.com/google/android-cuttlefish/8d08b814f3484d183bb827f5a5c2dd095dab44c8/base/host/deploy/capability_query.py";
    hash = "sha256-kW0NdZEIiZZngF77f8M+kUDI450AFjv3EJJI9sy58TQ=";
  };
  runtimeSupport = runCommand "cuttlefish-runtime-support" { } ''
    install -Dm755 ${capabilitySource} \
      $out/lib/cuttlefish-common/bin/capability_query.py
    install -Dm644 ${runtimeGroupFile} $out/etc/group
  '';
in
import ./rom-build-environment.nix {
  buildFHSEnv = arguments: buildFHSEnv (arguments // {
    name = "nns-cuttlefish-runtime-environment";
    targetPkgs = packages: (arguments.targetPkgs packages) ++ [
      runtimeSupport
      packages.alsa-lib
      packages.libpulseaudio
      packages.libdrm
      packages.wayland
      packages.expat
    ];
    # Keep group lookup inside the runtime instead of using the host nscd cache.
    extraBwrapArgs = (arguments.extraBwrapArgs or [ ]) ++ [ "--tmpfs /run/nscd" ];
  });
}
