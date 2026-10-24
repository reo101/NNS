{ pkgs, storage }:
let
  probe = storage.overrideAttrs (old: {
    pname = "nns-storage-handoff-probe";
    buildPhase = builtins.replaceStrings [ "zig build storage " ] [ "zig build storage-handoff-fixture " ] old.buildPhase;
    installPhase = ''
      install -Dm755 result/bin/nns-storage-handoff-fixture "$out/bin/nns-storage-module-controller"
    '';
  });
in pkgs.testers.runNixOSTest {
  name = "nns-module-storage-handoff";
  globalTimeout = 180;
  nodes.machine = { ... }: {
    boot.kernelPackages = pkgs.linuxPackages_6_1;
    environment.systemPackages = [ pkgs.util-linux ];
    virtualisation.memorySize = 768;
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /run/storage-handoff; cp ${storage}/bin/nns-storage-supervisor ${probe}/bin/nns-storage-module-controller /run/storage-handoff/; chmod 755 /run/storage-handoff/*")
    supervisor = "/run/storage-handoff/nns-storage-supervisor"
    child = "/run/storage-handoff/nns-storage-module-controller"
    namespace = machine.succeed("stat -Lc %i /proc/1/ns/mnt").strip()
    expected = "namespace=" + namespace + " capabilities=200000 inherited_descriptors=3"
    for argument in ("", " --check", " --mode"):
        assert machine.succeed(supervisor + argument).strip() == expected
    with subtest("enter init namespace before reducing capabilities"):
        assert machine.succeed("unshare -m " + supervisor + " --check").strip() == expected
    with subtest("discard caller namespace reference and unrelated descriptors"):
        command = "exec 9</dev/null; export NNS_STORAGE_TEST_LEAK=1 ANDROID_FILE__proc_1_ns_mnt=9; exec " + supervisor
        assert machine.succeed("sh -c '" + command + "'").strip() == expected
        assert machine.succeed("sh -c 'exec 0<&-; exec " + supervisor + "'").strip() == expected
    with subtest("refuse unsafe controller files and non-root callers"):
        machine.fail(supervisor + " unexpected")
        machine.fail("setpriv --reuid 65534 --regid 65534 --clear-groups " + supervisor)
        machine.succeed("chmod 777 " + child)
        machine.fail(supervisor)
        machine.succeed("chmod 755 " + child + "; ln " + child + " /run/storage-handoff/controller-link")
        machine.fail(supervisor)
        machine.succeed("rm /run/storage-handoff/controller-link; mv " + child + " /run/storage-handoff/controller-original; ln -s controller-original " + child)
        machine.fail(supervisor)
        machine.succeed("rm " + child)
        machine.fail(supervisor)
    with subtest("real module controller requires its SELinux domain"):
        machine.fail("${storage}/bin/nns-storage-module-controller --mode")
  '';
}
