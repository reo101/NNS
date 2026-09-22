{ lib, stdenvNoCC, launcher, dns, zip, python3, arch ? "arm64" }:
stdenvNoCC.mkDerivation {
  pname = "nns-module-${arch}";
  version = "3.1.0";
  src = lib.fileset.toSource {
    root = ../module;
    fileset = lib.fileset.unions [
      ../module/module.prop
      ../module/customize.sh
      ../module/post-fs-data.sh
      ../module/service.sh
      ../module/stage-etc.sh
      ../module/sepolicy.rule
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
    cp module.prop customize.sh post-fs-data.sh service.sh stage-etc.sh sepolicy.rule module/
    substituteInPlace module/customize.sh --replace-fail '@ARCH@' '${arch}'
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
