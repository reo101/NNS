{ pkgs, stockKernel }:
let
  llvm = pkgs.llvmPackages_19;
  kmod = pkgs.kmod.overrideAttrs (old: {
    buildInputs = old.buildInputs ++ [ pkgs.openssl ];
    configureFlags = old.configureFlags ++ [ "--with-openssl" ];
  });
  virtualDevice = pkgs.fetchzip {
    name = "791c3a12173894df4befa78f9718f7d70114c7a1.tar.gz";
    url = "https://android.googlesource.com/kernel/common-modules/virtual-device/+archive/791c3a12173894df4befa78f9718f7d70114c7a1.tar.gz";
    hash = "sha256-LPygSYlbLt2jLRBQQpLf9CQ1bTz/nhaieqyn8R8MJLI=";
    stripRoot = false;
  };
  virtioMedia = pkgs.fetchzip {
    name = "9b36409c9bc97ca7411751185f7139f05ac990ca.tar.gz";
    url = "https://android.googlesource.com/platform/external/virtio-media/+archive/9b36409c9bc97ca7411751185f7139f05ac990ca.tar.gz";
    hash = "sha256-nqIQjK+9Olbenr9JXepbbeccyzDovVW3v7JvG13vaW8=";
    stripRoot = false;
  };
  rust = pkgs.stdenvNoCC.mkDerivation {
    pname = "nns-storage-android-rust";
    version = "1.82.0";
    src = pkgs.fetchzip {
      name = "1.82.0.tar.gz";
      url = "https://android.googlesource.com/platform/prebuilts/rust/+archive/5c78b1e636b2bf68d46a6980437590fddca64147/linux-x86/1.82.0.tar.gz";
      hash = "sha256-rr5VJnUkAV4MunsrPtijwBwnXZkLtq/uzCufZw+shQc=";
      stripRoot = false;
    };
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib pkgs.zlib ];
    dontBuild = true;
    installPhase = ''
      mkdir -p "$out/lib/rustlib"
      cp -r bin lib64 "$out/"
      cp lib/*.so* "$out/lib/"
      cp -r lib/rustlib/x86_64-unknown-linux-gnu lib/rustlib/src "$out/lib/rustlib/"
    '';
  };
in pkgs.stdenv.mkDerivation {
  pname = "nns-storage-cuttlefish-kernel";
  version = "6.12.38";
  src = pkgs.fetchzip {
    name = "501f58f107ab.tar.gz";
    url = "https://github.com/aosp-mirror/kernel_common/archive/501f58f107abffc12890886764a1be3641742660.tar.gz";
    hash = "sha256-l0T2FMvtI4XL0z/eOUkj5JJAuKsGmJUg0YWSSb3FLcU=";
  };
  patches = [ ./libbpf-const.patch ];
  nativeBuildInputs = [ llvm.clang llvm.lld llvm.llvm rust pkgs.rust-bindgen-unwrapped
    pkgs.python3 pkgs.perl pkgs.bc pkgs.bison pkgs.flex pkgs.lz4 pkgs.lzop
    pkgs.pkg-config pkgs.pahole kmod pkgs.cpio pkgs.xz ];
  buildInputs = [ pkgs.openssl pkgs.elfutils pkgs.zlib ];
  hardeningDisable = [ "all" ];
  dontStrip = true;
  dontFixup = true;
  enableParallelBuilding = true;
  env = {
    KBUILD_BUILD_USER = "nns-storage-lab";
    KBUILD_BUILD_HOST = "nns-storage-lab";
    KBUILD_BUILD_TIMESTAMP = "Thu Aug 21 21:28:12 UTC 2025";
    KBUILD_BUILD_VERSION = "1";
    RUSTC_BOOTSTRAP = "1";
    RUST_LIB_SRC = "${rust}/lib/rustlib/src/rust/library";
    LIBCLANG_PATH = "${llvm.libclang.lib}/lib";
  };
  postPatch = ''
    patchShebangs scripts tools/objtool tools/bpf tools/build tools/lib arch/x86/tools
  '';
  configurePhase = ''
    flags=(LLVM=1 LLVM_IAS=1 ARCH=x86_64 O=out CC=${llvm.clang.cc}/bin/clang HOSTCC=${llvm.clang}/bin/clang HOSTCXX=${llvm.clang}/bin/clang++)
    mkdir out
    test "$(sha256sum ${stockKernel} | cut -d ' ' -f 1)" = 0f6cf8acaf39bc49138677c695d574b3f9f551d0a21a467e560916467f5044f8
    scripts/extract-ikconfig ${stockKernel} > original.config
    scripts/kconfig/merge_config.sh -m -O out original.config \
      ${virtualDevice}/virtual_device_core.fragment ${virtualDevice}/virtual_device.fragment
    # Retain the stock signing setting, despite the device fragment's override.
    scripts/config --file out/.config --enable BTRFS_FS --enable MODULE_SIG_ALL \
      --set-str LOCALVERSION '-android16-5-g501f58f107ab-ab13974591' --disable LOCALVERSION_AUTO
    make "''${flags[@]}" olddefconfig
    for option in BTRFS_FS BLK_DEV_LOOP F2FS_FS FS_ENCRYPTION SECURITY_SELINUX RUST CFI_CLANG CFI_ICALL_NORMALIZE_INTEGERS MODVERSIONS MODULE_SIG MODULE_SIG_ALL; do
      grep -qx "CONFIG_$option=y" out/.config
    done
    for option in FAILOVER VIRTIO_NET DRM_VIRTIO_GPU VIRTIO_INPUT SND_VIRTIO; do
      grep -qx "CONFIG_$option=m" out/.config
    done
    grep -qx '# CONFIG_MODULE_FORCE_LOAD is not set' out/.config
    grep -qx '# CONFIG_CFI_PERMISSIVE is not set' out/.config
    grep -qx '# CONFIG_MODULE_SIG_FORCE is not set' original.config
    grep -qx '# CONFIG_MODULE_SIG_FORCE is not set' out/.config
    test "$(make -s "''${flags[@]}" kernelrelease)" = 6.12.38-android16-5-g501f58f107ab-ab13974591
    scripts/diffconfig original.config out/.config > configuration-diff.txt
  '';
  buildPhase = ''
    jobs=$NIX_BUILD_CORES
    if [ "$jobs" -gt 8 ]; then jobs=8; fi
    make -j"$jobs" "''${flags[@]}" bzImage modules
    cp -r ${virtualDevice} virtual-device
    cp -r ${virtioMedia} virtio-media
    chmod -R u+w virtual-device virtio-media
    printf '%s\n' 'obj-m := goldfish_address_space.o goldfish_pipe.o goldfish_sync.o' \
      'ccflags-y += -I$(src)/../uapi' > virtual-device/goldfish_drivers/Kbuild
    printf '%s\n' 'obj-m := v4l2loopback.o' > virtual-device/v4l2loopback/Kbuild
    external_modules=("$PWD/virtual-device/goldfish_drivers" "$PWD/virtual-device/v4l2loopback" \
      "$PWD/virtual-device/vkms" "$PWD/virtio-media/driver")
    for directory in "''${external_modules[@]}"; do
      make -j"$jobs" "''${flags[@]}" M="$directory" CONFIG_DRM_VKMS=m modules
    done
  '';
  installPhase = ''
    staging=$PWD/module-staging
    make "''${flags[@]}" INSTALL_MOD_PATH="$staging" INSTALL_MOD_STRIP=1 modules_install
    for directory in "''${external_modules[@]}"; do
      make "''${flags[@]}" M="$directory" CONFIG_DRM_VKMS=m \
        INSTALL_MOD_PATH="$staging" INSTALL_MOD_STRIP=1 modules_install
    done
    mkdir -p "$out/modules"
    while IFS= read -r -d $'\0' module; do
      name=$(basename "$module")
      test ! -e "$out/modules/$name"
      cp "$module" "$out/modules/$name"
    done < <(find "$staging/lib/modules" -type f -name '*.ko' -print0 | sort -z)
    cp out/arch/x86/boot/bzImage "$out/kernel"
    cp out/.config "$out/config"
    cp configuration-diff.txt "$out/"
    cp out/include/config/kernel.release "$out/"
    cp out/Module.symvers "$out/Module.symvers"
    cp out/vmlinux out/System.map "$out/"
    for directory in "''${external_modules[@]}"; do
      cat "$directory/Module.symvers" >> "$out/Module.symvers"
    done
    python3 ${./check-module-versions.py} --modules "$out/modules" \
      --symvers "$out/Module.symvers" --release "$out/kernel.release" \
      --output "$out/module-versions.json"
  '';
}
