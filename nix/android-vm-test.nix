{ pkgs, lib, androidSdk, kernel, module, sources }:
let
  bootstrap = pkgs.buildEnv {
    name = "nns-test-bootstrap";
    paths = [ pkgs.nix pkgs.bash pkgs.coreutils pkgs.curl pkgs.cacert ];
    pathsToLink = [ "/bin" "/etc/ssl" ];
  };
  closure = pkgs.closureInfo { rootPaths = [ bootstrap ]; };
  seed = pkgs.runCommand "nns-test-seed" { nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ]; } ''
    mkdir "$out"
    # Nix store optimisation can hard-link even symlink inodes. Toybox tar
    # does not faithfully restore all such links; emit each entry separately.
    tar --hard-dereference -czf "$out/store.tar.gz" -T ${closure}/store-paths
    cp ${closure}/registration "$out/registration"
  '';
  ksud = pkgs.runCommand "nns-test-ksud" { nativeBuildInputs = [ pkgs.unzip ]; } ''
    unzip -p ${sources.sukisuManager} lib/x86_64/libksud.so > "$out"
    chmod +x "$out"
  '';
  apk = pkgs.callPackage ./android-test-apk.nix { inherit androidSdk; };
  appFlow = pkgs.replaceVars ../tests/android/app-flow.sh { HELLO = pkgs.hello; };
  spec = {
    sdk = "${androidSdk}/libexec/android-sdk";
    kernel = "${kernel}/kernel-ranchu";
    module = "${module}/module";
    inherit seed ksud bootstrap appFlow;
    nix = "${pkgs.nix}";
    hello = "${pkgs.hello}";
    apk = "${apk}/nns-probe.apk";
    # cmdline-tools (avdmanager/sdkmanager) need a JRE; the build sandbox has none.
    java = "${pkgs.jdk17_headless}";
  };
in
pkgs.testers.runNixOSTest {
  name = "nns-android-app-flow";
  globalTimeout = 20 * 60;
  nodes.cache = { ... }: {
    virtualisation = {
      memorySize = 1024;
      cores = 2;
      diskSize = 4096;
      forwardPorts = [
        { from = "host"; proto = "tcp"; host.address = "127.0.0.1"; host.port = 31080; guest.port = 5000; }
        { from = "host"; proto = "udp"; host.address = "127.0.0.1"; host.port = 31553; guest.port = 53; }
        { from = "host"; proto = "tcp"; host.address = "127.0.0.1"; host.port = 31553; guest.port = 53; }
      ];
    };
    system.extraDependencies = [ pkgs.hello ];
    services.nix-serve = { enable = true; openFirewall = true; secretKeyFile = "/run/nns-cache.sec"; };
    systemd.services.nns-cache-key = {
      before = [ "nix-serve.service" ];
      requiredBy = [ "nix-serve.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        ${pkgs.nix}/bin/nix-store --generate-binary-cache-key nns-test /run/nns-cache.sec /run/nns-cache.pub
      '';
    };
    services.dnsmasq = {
      enable = true;
      settings = { no-resolv = true; address = [ "/nns-cache.test/10.0.2.2" ]; log-queries = true; };
    };
    networking.firewall.allowedTCPPorts = [ 53 ];
    networking.firewall.allowedUDPPorts = [ 53 ];
  };
  # Like SteamlessLink: sibling Android/NixOS VMs, not nested virtualization.
  testScript = ''
    import json
    spec = json.loads(${builtins.toJSON (builtins.toJSON spec)})
    ${builtins.readFile ../tests/android/vm-test.py}
  '';
}
