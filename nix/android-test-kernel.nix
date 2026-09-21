{ lib, stdenv, fetchurl, sources, stockKernel, llvmPackages_18, python3,
  perl, bc, bison, flex, openssl, elfutils, zlib, lz4, pkg-config, pahole }:
stdenv.mkDerivation {
  pname = "nns-emulator-kernel";
  version = "6.6.50";
  src = fetchurl {
    name = "emulator-common.tar.gz";
    url = "https://github.com/aosp-mirror/kernel_common/archive/8adecb593e9b745427da9d61c3cc8bc4857de209.tar.gz";
    hash = "sha256-QLWMd9G2pIASt/FDRhiHug1VHGsbIC5/RpbBbJ/QjXw=";
    curlOptsList = [ "-A" "OpenAI File Downloader, XaiImageApiFetch/1.0" ];
  };
  nativeBuildInputs = [ llvmPackages_18.clang llvmPackages_18.lld llvmPackages_18.llvm
    python3 perl bc bison flex lz4 pkg-config pahole ];
  buildInputs = [ openssl elfutils zlib ];
  hardeningDisable = [ "all" ];
  dontStrip = true;
  dontFixup = true;
  enableParallelBuilding = true;
  postPatch = ''
    mkdir KernelSU
    tar -xf ${sources.sukisu} --strip-components=1 -C KernelSU
    chmod -R u+w KernelSU
    (cd KernelSU; patch -p1 < ${../kernel/patches/sukisu-version.patch})
    ln -s ../KernelSU/kernel drivers/kernelsu
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
    sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
    python3 ${../tests/android/patch-kernel.py} ${../kernel/patches/nns-seccomp-bypass.patch}
    patchShebangs scripts tools/objtool tools/bpf tools/build tools/lib arch/x86/tools
  '';
  env = {
    KBUILD_BUILD_USER = "build-user";
    KBUILD_BUILD_HOST = "nns-test";
    KBUILD_BUILD_TIMESTAMP = "Fri Oct 18 23:59:20 UTC 2024";
    KBUILD_BUILD_VERSION = "1";
    KCFLAGS = "-Wno-error";
  };
  configurePhase = ''
    flags=(LLVM=1 LLVM_IAS=1 ARCH=x86_64 O=out CC=${llvmPackages_18.clang.cc}/bin/clang HOSTCC=${stdenv.cc}/bin/cc HOSTCXX=${stdenv.cc}/bin/c++)
    mkdir out
    stock=${stockKernel}
    # Refuse silently mixing a new SDK kernel/modules with our pinned source.
    strings "$stock" | grep -F '6.6.50-android15-8-g8adecb593e9b-ab12525588'
    scripts/extract-ikconfig "$stock" > out/.config
    scripts/config --file out/.config --enable USER_NS --enable KSU \
      --disable KSU_SUSFS --disable KPM --disable KSU_DEBUG \
      --disable MODULE_SIG_PROTECT --disable MODULE_SIG_ALL \
      --disable LOCALVERSION_AUTO --disable TRIM_UNUSED_KSYMS \
      --set-str LOCALVERSION '-android15-8-g8adecb593e9b-ab12525588'
    make "''${flags[@]}" olddefconfig
    grep -qx 'CONFIG_USER_NS=y' out/.config
    grep -qx 'CONFIG_KSU=y' out/.config
    grep -qx 'CONFIG_SECURITY_SELINUX=y' out/.config
    grep -qx 'CONFIG_SECCOMP_FILTER=y' out/.config
    grep -qx 'CONFIG_MODVERSIONS=y' out/.config
  '';
  buildPhase = ''
    make -j"$NIX_BUILD_CORES" "''${flags[@]}" security/selinux/
    make -j"$NIX_BUILD_CORES" "''${flags[@]}" drivers/kernelsu/ksu.o
    make -j"$NIX_BUILD_CORES" "''${flags[@]}" bzImage
  '';
  installPhase = ''
    mkdir -p "$out"
    cp out/arch/x86/boot/bzImage "$out/kernel-ranchu"
    cp out/.config "$out/config"
    cp out/include/config/kernel.release "$out/"
  '';
  meta = {
    description = "Android 35 emulator ACK with NNS userns/seccomp and SukiSU";
    platforms = [ "x86_64-linux" ];
    license = lib.licenses.gpl2Only;
  };
}
