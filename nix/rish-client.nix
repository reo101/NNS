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
  version = "1";
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
  postPatch = ''
    substituteInPlace rish/src/main/java/rikka/rish/RishTerminal.java \
      --replace-fail 'start(tty, getFd(stdin, 1), getFd(stdout, 0), getFd(stdout, 0))' \
        'start(tty, getFd(stdin, 1), getFd(stdout, 0), getFd(stderr, 0))' \
      --replace-fail 'data, null, 0);' 'data, reply, 0);' \
      --replace-fail 'exitCode = requestExitCode();' \
        'do {
            exitCode = requestExitCode();
            if (exitCode == Integer.MAX_VALUE) Thread.sleep(10);
        } while (exitCode == Integer.MAX_VALUE);' \
      --replace-fail 'exitCode = -1;' 'e.printStackTrace(System.err); exitCode = -1;'
  '';
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
      rish/src/main/java/rikka/rish/{FileDescriptors,Rish,RishConfig,RishConstants,RishHost,RishTerminal}.java \
      generated/moe/shizuku/server/*.java ShizukuShellLoader.java
    ${sdk}/libexec/android-sdk/build-tools/35.0.0/d8 \
      --min-api 29 --lib "$android" --output dex \
      classes/rikka/rish/*.class classes/rikka/shizuku/shell/*.class \
      classes/moe/shizuku/server/*.class
  '';
  installPhase = ''cp dex/classes.dex "$out"'';
  meta.license = lib.licenses.asl20;
}
