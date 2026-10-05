{ lib, stdenvNoCC, launcher, dns, policy, rish, zip, python3, arch ? "arm64",
  # Assigned per install; supply the host's app uid/gid, e.g.
  # mkModule { appUid = ...; appGid = ...; } in outputs.nix.
  appUid ? throw "nix/module.nix: appUid not supplied; pass the host's Android app uid",
  appGid ? throw "nix/module.nix: appGid not supplied; pass the host's Android app gid",
  # The application id that owns the shizuku_server; staged as the rish
  # wrappers' default (NNS_APPLICATION_ID overrides per invocation).
  appId ? throw "nix/module.nix: appId not supplied; pass the host's Android application id" }:
stdenvNoCC.mkDerivation {
  pname = "nns-module-${arch}";
  version = "3.2.0";
  src = lib.fileset.toSource {
    root = ../module;
    fileset = lib.fileset.unions [
      ../module/module.prop
      ../module/customize.sh
      ../module/post-fs-data.sh
      ../module/service.sh
      ../module/stage-etc.sh
      ../module/system-generation.sh
      ../module/etc/profile
      ../module/etc/nix/nix.conf
    ];
  };
  nativeBuildInputs = [ zip python3 ];
  dontConfigure = true;
  dontFixup = true; # Keep Android shebangs and the static ARM64 ELF untouched.
  allowedReferences = [ ];
  buildPhase = ''
    runHook preBuild
    mkdir -p module/bin module/lib module/etc/nix
    cp ${launcher}/bin/nix-enter module/bin/nix-enter
    cp ${dns}/bin/nns-resolver module/bin/nns-resolver
    cp ${dns}/lib/libnns-dns.so module/lib/libnns-dns.so
    cp ${rish}/bin/rish ${rish}/bin/su ${rish}/bin/sudo ${rish}/bin/rish-probe module/bin/
    cp ${rish}/lib/rish.dex module/lib/rish.dex
    cp module.prop customize.sh post-fs-data.sh service.sh stage-etc.sh system-generation.sh module/
    cp ${policy} module/sepolicy.rule
    substituteInPlace module/customize.sh --replace-fail '@ARCH@' '${arch}'
    # The app uid/gid/appId are assigned per install; every build names them.
    substituteInPlace module/post-fs-data.sh --replace-fail '@APP_UID@' '${builtins.toString appUid}' --replace-fail '@APP_GID@' '${builtins.toString appGid}' --replace-fail '@APP_ID@' '${appId}'
    # The wrappers carry the app id only as the baked fallback default;
    # the staged /data/nix/etc/app-id file is the per-host source.
    substituteInPlace module/bin/rish module/bin/rish-probe --replace-fail '@APP_ID@' '${appId}'
    substituteInPlace module/stage-etc.sh --replace-fail '@APP_UID@' '${builtins.toString appUid}' --replace-fail '@APP_GID@' '${builtins.toString appGid}' --replace-fail '@APP_ID@' '${appId}'
    cp etc/profile module/etc/
    cp etc/nix/nix.conf module/etc/nix/
    touch module/skip_mount
    chmod 755 module/bin/* module/*.sh
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r module "$out/module"
    find "$out/module" -exec touch -h -t 198001010000 {} +
    (cd "$out/module"; find . -type f -print | LC_ALL=C sort | zip -X -9 "$out/nns-module.zip" -@)
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    python3 ${../tests/check-module.py} "$out/nns-module.zip" ${arch}
  '';
  meta = {
    description = "Native Nix Store module ZIP for Magisk and KernelSU managers";
    platforms = lib.platforms.unix;
  };
}
