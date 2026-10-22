{ lib, pkgs, stdenvNoCC, fetchFromGitHub, jdk17 }:
let
  androidPkgs = import pkgs.path {
    system = pkgs.stdenv.buildPlatform.system;
    config = { allowUnfree = true; android_sdk.accept_license = true; };
  };
  sdk = (androidPkgs.androidenv.composeAndroidPackages {
    platformVersions = [ "35" ];
    buildToolsVersions = [ "35.0.0" ];
    includeNDK = false;
    includeEmulator = false;
    includeSystemImages = false;
  }).androidsdk;
in
stdenvNoCC.mkDerivation {
  pname = "nns-rish-client";
  version = "2";
  src = fetchFromGitHub {
    owner = "RikkaApps";
    repo = "Shizuku-API";
    rev = "a27f6e4151ba7b39965ca47edb2bf0aeed7102e5";
    hash = "sha256-+D/RTV0Tu+cTtO7wTfggl5ql/5Whi4VWeV16f6uA9kI=";
  };
  nativeBuildInputs = [ jdk17 ];
  dontConfigure = true;
  dontFixup = true;
  allowedReferences = [ ];
  buildPhase = ''
    android=${sdk}/libexec/android-sdk/platforms/android-35/android.jar
    mkdir classes dex generated
    for definition in aidl/src/main/aidl/moe/shizuku/server/*.aidl; do
      ${sdk}/libexec/android-sdk/build-tools/35.0.0/aidl \
        -p${sdk}/libexec/android-sdk/platforms/android-35/framework.aidl \
        -Iaidl/src/main/aidl -o generated "$definition"
    done
    cp ${../integrations/shizuku/ShizukuShellLoader.java} ShizukuShellLoader.java
    javac --release 8 -classpath "$android" -d classes \
      generated/moe/shizuku/server/*.java ShizukuShellLoader.java
    ${sdk}/libexec/android-sdk/build-tools/35.0.0/d8 \
      --min-api 29 --lib "$android" --output dex \
      classes/rikka/shizuku/shell/*.class \
      classes/moe/shizuku/server/*.class
  '';
  installPhase = ''cp dex/classes.dex "$out"'';
  meta.license = lib.licenses.asl20;
}
