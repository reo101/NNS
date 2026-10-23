{
  pkgs,
  backend,
  variant,
}:
let
  inherit (pkgs) lib;
  base = "/data/nns-service-managers";
  profileWriter = pkgs.writeShellScript "nns-manager-profile-writer" ''
    set -eu
    test "$NIX_REMOTE" = local
    while [ "$1" != --profile ]; do shift; done
    profile=$2; shift 2
    test "$1" = --set
    ${pkgs.coreutils}/bin/ln -sfn "$2" "$profile"
  '';
  nixTools = pkgs.runCommand "nns-manager-fake-nix" { } ''
    mkdir -p "$out/bin"
    ln -s ${profileWriter} "$out/bin/nix-env"
    cat > "$out/bin/nix" <<'EOF'
    #!${pkgs.runtimeShell}
    exec ${pkgs.python3}/bin/python3 ${daemonPing}
    EOF
    cat > "$out/bin/nix-daemon" <<'EOF'
    #!${pkgs.runtimeShell}
    exec ${pkgs.python3}/bin/python3 ${daemon}
    EOF
    chmod 755 "$out/bin/nix" "$out/bin/nix-daemon"
  '';
  daemonPing = pkgs.writeText "nns-manager-test-ping.py" ''
    import os, socket
    assert os.environ.get('NIX_REMOTE') == 'daemon'
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(1)
        connection.connect('${base}/daemon.control')
        assert connection.recv(5) == b'ready'
  '';
  daemon = pkgs.writeText "nns-manager-test-daemon.py" ''
    import fcntl, os, signal, socket, sys
    from pathlib import Path
    base = Path('${base}')
    descriptor = (base / 'daemon.lock').open('a')
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        (base / 'duplicate-owner').touch()
        sys.exit(125)
    with (base / 'daemon-pids').open('a') as record:
        record.write(str(os.getpid()) + '\n')
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    (base / 'daemon.control').unlink(missing_ok=True)
    server.bind(str(base / 'daemon.control'))
    server.listen()
    (base / 'daemon-ready').touch()
    def stop(*_):
        (base / 'daemon-ready').unlink(missing_ok=True)
        server.close()
        (base / 'daemon.control').unlink(missing_ok=True)
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while True:
        connection, _ = server.accept()
        with connection:
            connection.sendall(b'ready')
  '';
  serviceType =
    if
      builtins.elem variant [
        "typechange"
        "finite-failure"
      ]
    then
      "oneshot"
    else
      "longrun";
  workerCommand =
    if variant == "update" then
      ''
        printf '%s\n' "$$" >> ${base}/worker-pids
        echo updated > ${base}/worker-version
        exec ${pkgs.coreutils}/bin/sleep infinity
      ''
    else
      ''
        printf '%s\n' "$$" >> ${base}/worker-pids
        echo base > ${base}/worker-version
        exec ${pkgs.coreutils}/bin/sleep infinity
      '';
  worker = pkgs.writeShellScript "nns-manager-worker" ''
    test "$(pwd -P)" = ${base}/state/services/worker || exit 27
    ${workerCommand}
  '';
  prepare = pkgs.writeShellScript "nns-manager-prepare" ''
    echo attempt >> ${base}/prepare-attempts
    if test -f ${base}/hang; then
      ${pkgs.runtimeShell} -c 'trap "" TERM INT; while :; do sleep 60; done' &
      echo "$!" > ${base}/hung-child
      trap "" TERM INT
      wait
    fi
    test -f ${base}/release
  '';
  finiteWorker = pkgs.writeShellScript "nns-manager-finite-worker" ''
    echo finite >> ${base}/finite-runs
    ${lib.optionalString (variant == "finite-failure") "test -f ${base}/finite-release"}
  '';
in
(import ../../nix/nns-system.nix { nixpkgs = pkgs.path; } {
  system = pkgs.stdenv.hostPlatform.system;
  inherit pkgs;
  modules = [
    {
      nix.package = nixTools;
      system = {
        serviceManager = backend;
        stateDirectory = "${base}/state";
        etcDirectory = "${base}/etc";
        profileDirectory = "${base}/profiles";
        nixConfDirectory = "${base}/nix";
        launcher = "${base}/bin/launcher";
        directories = {
          shared = {
            path = "${base}/shared";
            mode = "0710";
          };
          labeled = {
            path = "${base}/labeled";
            mode = "0750";
            startAt = "unlock";
            selinuxContextFromAccount = "root";
          };
        };
      };
      services.runit = {
        worker = {
          nns = {
            type = serviceType;
            after = lib.optionals (variant == "gated") [ "unlock" ];
          };
          process.argv = [ (if serviceType == "oneshot" then finiteWorker else worker) ];
        };
        prepare = {
          nns.type = "oneshot";
          process.argv = [ prepare ];
        };
        consumer = {
          nns.after = [
            "prepare"
            "worker"
          ];
          process.argv = [
            (pkgs.writeShellScript "nns-manager-consumer" ''
              echo "$$" >> ${base}/consumer-pids
              : > ${base}/consumer-ready
              exec ${pkgs.coreutils}/bin/sleep infinity
            '')
          ];
        };
        unlock = {
          nns = {
            type = "oneshot";
            startAt = "unlock";
          };
          process.argv = [
            (pkgs.writeShellScript "nns-manager-unlock" ''
              echo unlocked >> ${base}/unlock-runs
            '')
          ];
        };
        after-unlock = {
          nns = {
            type = "oneshot";
            after = [ "unlock" ];
          };
          process.argv = [
            (pkgs.writeShellScript "nns-manager-after-unlock" ''
              echo after-unlock >> ${base}/unlock-runs
            '')
          ];
        };
      }
      // lib.optionalAttrs (variant != "remove") {
        removal-consumer = {
          nns.after = [ "removable" ];
          process.argv = [
            "${pkgs.coreutils}/bin/sleep"
            "infinity"
          ];
        };
        removable = {
          nns.type = "oneshot";
          process.argv = [
            (pkgs.writeShellScript "nns-manager-removable" ''
              echo present > ${base}/removable
            '')
          ];
        };
      };
    }
  ];
}).config.system.build.toplevel
