{
  lib,
  stdenv,
  sources,
  clang,
  sccache,
  python3,
  perl,
  bc,
  bison,
  flex,
  openssl,
  elfutils,
  zlib,
  pkg-config,
  pahole,
  which,
}:
stdenv.mkDerivation {
  pname = "cheetah-kernel";
  version = "6.1.162-sukisu-nns";
  src = sources.pantah;
  nativeBuildInputs = [
    clang
    sccache
    python3
    perl
    bc
    bison
    flex
    pkg-config
    pahole
    which
  ];
  buildInputs = [
    openssl
    elfutils
    zlib
  ];
  hardeningDisable = [ "all" ];
  dontStrip = true;
  dontFixup = true;
  enableParallelBuilding = true;

  # Extract only ACK, not the entire Kleaf workspace and its prebuilt toolchains.
  unpackPhase = ''
    runHook preUnpack
    mkdir source
    tar -xf "$src" --strip-components=3 -C source kernel-pantah-15260412/common/ack
    chmod -R u+w source
    cd source
    runHook postUnpack
  '';
  patchPhase = ''
    runHook prePatch
    mkdir KernelSU .inputs .inputs/susfs
    tar -xf ${sources.sukisu} --strip-components=1 -C KernelSU
    (cd KernelSU; patch -p1 < ${./patches/sukisu-version.patch})
    tar -xf ${sources.susfs} --strip-components=1 -C .inputs/susfs
    chmod -R u+w KernelSU .inputs
    ln -s ../KernelSU/kernel drivers/kernelsu
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
    sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig

    cp .inputs/susfs/kernel_patches/fs/susfs.c fs/
    cp .inputs/susfs/kernel_patches/include/linux/susfs{,_def}.h include/linux/
    (cd .inputs/susfs; patch -p1 --fuzz=0 < ${./patches/susfs-compat.patch})
    patch -p1 < .inputs/susfs/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch
    patch -p1 < ${./patches/susfs-newuname.patch}
    patch -p1 < ${./patches/susfs-taskmmu.patch}
    test -z "$(find . -name '*.rej' -print -quit)"
    patchShebangs scripts tools arch/arm64
    runHook postPatch
  '';

  env = {
    KCFLAGS = "-O2 -Wno-error";
    KBUILD_BUILD_USER = "build-user";
    KBUILD_BUILD_HOST = "build-host";
    KBUILD_BUILD_VERSION = "1";
    KBUILD_BUILD_TIMESTAMP = "Fri Jan 9 16:33:46 UTC 2026";
    KBUILD_GENDWARFKSYMS_STABLE = "1";
  };
  configurePhase = ''
    runHook preConfigure
    export HOME="$TMPDIR" SCCACHE_DIR="$TMPDIR/sccache"
    export CC="sccache ${clang}/bin/clang"
    export HOSTCC="sccache ${stdenv.cc}/bin/gcc"
    export HOSTCXX="sccache ${stdenv.cc}/bin/g++"
    flags=(LLVM=1 LLVM_IAS=1 ARCH=arm64 O=out "CC=$CC" "HOSTCC=$HOSTCC" "HOSTCXX=$HOSTCXX")
    mkdir -p out
    cp ${./rom.config} out/.config
    make "''${flags[@]}" olddefconfig
    cat ${./nns.config} >> out/.config
    make "''${flags[@]}" olddefconfig
    python3 ${./check.py} out ${./avb.json} --config-only
    # configs.c embeds config_data.gz via assembler .incbin, invisible to the
    # C preprocessor cache. Never reuse that object across resolved configs.
    export SCCACHE_C_CUSTOM_CACHE_BUSTER="$(sha256sum out/.config | cut -d' ' -f1)"
    runHook postConfigure
  '';
  buildPhase = ''
    runHook preBuild
    # Generate SELinux's private headers before validating the root integration.
    make -j"$NIX_BUILD_CORES" "''${flags[@]}" V=1 security/selinux/
    make -j"$NIX_BUILD_CORES" "''${flags[@]}" V=1 drivers/kernelsu/ksu.o
    make -j"$NIX_BUILD_CORES" "''${flags[@]}" V=1 Image
    sccache --show-stats
    runHook postBuild
  '';
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python3 ${./check.py} out ${./avb.json}
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp out/arch/arm64/boot/Image out/System.map out/vmlinux.symvers "$out/"
    cp out/.config "$out/config"
    cp out/include/config/kernel.release "$out/kernel.release"
    cp ${./avb.json} "$out/avb.json"
    runHook postInstall
  '';
  meta = {
    description = "Cheetah ACK kernel with SukiSU Ultra, SuSFS, USER_NS and USB HID";
    platforms = [ "x86_64-linux" ];
    license = lib.licenses.gpl2Only;
  };
}
