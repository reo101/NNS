{ lib, stdenvNoCC, autoPatchelfHook, stdenv, zlib, zstd, ncurses, libxml2_13, sources }:
stdenvNoCC.mkDerivation {
  pname = "cheetah-clang";
  version = "17.0.6";
  src = sources.clang;
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib zlib zstd ncurses libxml2_13 ];
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/lib"
    # Kernel build tools only. No debugger, host SDK, or bundled C++ libraries.
    for tool in clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump \
                llvm-readelf llvm-strip llvm-size llvm-strings; do
      cp -L "bin/$tool" "$out/bin/$tool"
    done
    cp -r lib/clang "$out/lib/"
    runHook postInstall
  '';
  meta = {
    description = "Upstream LLVM 17.0.6 binaries used by the boot-tested cheetah kernel";
    platforms = [ "x86_64-linux" ];
    license = lib.licenses.asl20;
  };
}
