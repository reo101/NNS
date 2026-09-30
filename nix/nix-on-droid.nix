# Nix-on-Droid module: run NoD sessions through the NNS launcher instead of
# proot.
#
# Sessions exec `/data/nix/bin/nix-enter`, which builds a private user+mount
# namespace with the canonical root-owned store at `/nix` and hands off to the
# NoD session shell. Store and profile writes go through the root daemon
# (`NIX_REMOTE=daemon`). This replaces proot entirely: no link2symlink, no
# fake `/proc`, no static proot roulette.
#
# The proot-specific activation steps are overridden to write into
# `build.installationDir` (the app prefix) directly instead of proot-mapped
# `/bin`, `/usr`, `/etc`. The NoD generation profile
# (`/nix/var/nix/profiles/nix-on-droid`) is root-writable in an NNS store, so
# generation switching keeps working; session packages get their own profile
# at `$HOME/.nix-profile`, which the app UID owns.
#
# Usage (inside a Nix-on-Droid configuration):
#
#   imports = [ (import "/data/nix/etc/nix-on-droid-module.nix") ];
#
# First activation must be run manually through the launcher, e.g.:
#
#   nix-enter -- nix build --impure --no-link \
#     <flake>#nixOnDroidConfigurations.<device>.activationPackage
#   nix-enter -- /nix/store/<gen>-nix-on-droid-generation/activate

{ config, lib, options, pkgs, ... }:

let
  inherit (lib) attrNames concatMapStringsSep map mkEnableOption mkForce mkIf mkOption optional toString types;
  cfg = config.nns;

  installDir = config.build.installationDir;

  portableServices = import "${pkgs.path}/lib/services/lib.nix" { inherit lib; };
  # The pinned portable base lacks process.environment; newer revisions may
  # already declare it, so test the base before adding the compatibility option.
  portableHasEnvironment = (lib.evalModules {
    class = "service";
    modules = [ (import "${pkgs.path}/lib/services/service.nix" { inherit pkgs; }) ];
  }).options.process ? environment;
  serviceSubmodule = (portableServices.configure {
    serviceManagerPkgs = pkgs;
    extraRootModules = [
      ({ name, ... }: {
        options.process = lib.optionalAttrs (!portableHasEnvironment) {
          environment = mkOption {
            type = types.lazyAttrsOf (types.nullOr (
              types.coercedTo (types.either types.path types.package) (value: "${value}") types.str
            ));
            default = { };
            description = "Environment variables for the service process; null unsets a variable.";
          };
        };
        options.nns = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Whether the ${name} service is supervised.";
          };
          startAt = mkOption {
            type = types.enum [ "boot" "unlock" ];
            default = "boot";
            description = "Wait for first unlock before starting this service when set to unlock.";
          };
          after = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Wait for these runit services to be running before starting.";
          };
        };
      })
    ];
  }).serviceSubmodule;

  rishDex = pkgs.runCommand "nns-rish-shizuku.dex" { nativeBuildInputs = [ pkgs.unzip ]; } ''
    unzip -p ${pkgs.fetchurl {
      url = "https://github.com/RikkaApps/Shizuku/releases/download/v13.6.0/shizuku-v13.6.0.r1086.2650830c-release.apk";
      hash = "sha256-bic6sOmRxOebyLG7ubndc5zKwahxKlQaIUB4iGt7eQ8=";
    }} assets/rish_shizuku.dex > "$out"
  '';
  nnsRish = pkgs.writeScript "nns-rish" /* sh */ ''
    #!${pkgs.runtimeShell}
    # No service-list or pidof preflight: neither reliably sees Shizuku here.
    export RISH_APPLICATION_ID=com.termux.nix
    export NNS_RISH_PROPERTY_INFO_SHIM=1
    export LD_PRELOAD=/data/nix/lib/libnns-dns.so
    export PATH=/bin:/system/bin
    exec /system/bin/app_process -Djava.class.path="${rishDex}" /system/bin \
      --nice-name=rish rikka.shizuku.shell.ShizukuShellLoader "$@"
  '';
  nnsSu = pkgs.writeScript "nns-su" /* sh */ ''
    #!${pkgs.runtimeShell}
    exec "$HOME/.nns-bin/rish" "$@"
  '';
  nnsSudo = pkgs.writeScript "nns-sudo" /* sh */ ''
    #!${pkgs.runtimeShell}
    exec "$HOME/.nns-bin/rish" -c "$*"
  '';

  # Sourced by the login shell; sets PATH (nix-on-droid-path), session
  # variables and home-manager environment from the user profile.
  loginInner = pkgs.writeScript "nns-login-inner" /* bash */ ''
    #!${pkgs.runtimeShell}

    set -eo pipefail

    # The launcher starts sessions with the raw inherited environment
    # (HOME=/ USER=root under su, or unset for apps); session-init's
    # home-manager PATH and nix.sh both interpolate $HOME while sourcing,
    # so it must be correct before anything else runs.
    export HOME="${config.user.home}"
    export USER="${config.user.userName}"

    . "${config.build.sessionInit}/etc/profile.d/nix-on-droid-session-init.sh"

    # NoD's dnshack resolver expects proot's removed /android mapping.
    # Use the NNS Bionic resolver and terminal shim for every login session.
    export LD_PRELOAD=/data/nix/lib/libnns-dns.so

    mkdir -p "$HOME/.nns-bin"
    ln -sf "${nnsRish}" "$HOME/.nns-bin/rish"
    ln -sf "${nnsSu}" "$HOME/.nns-bin/su"
    ln -sf "${nnsSudo}" "$HOME/.nns-bin/sudo"
    export PATH="$HOME/.nns-bin:$PATH"

    if [ "$#" -gt 0 ]; then
      exec "$@"
    fi

    exec -a "-nix-on-droid" ${config.user.shell}
  '';

  # Entry point execed by the Nix-on-Droid app. Runs on Android (bionic),
  # before any namespace exists.
  login = pkgs.writeScript "nns-login" /* bash */ ''
    #!/system/bin/sh
    # This file is generated by NNS. DO NOT EDIT.

    set -eu

    export USER="${config.user.userName}"
    export HOME="${config.user.home}"
    export NIX_REMOTE=daemon
    export NIX_CONF_DIR=/nix/etc/nix
    export TMPDIR="$HOME/tmp"

    # The app's session PATH may not include /system/bin (Termux-style),
    # so no PATH lookups before the launcher takes over.
    /system/bin/mkdir -p "$TMPDIR"

    exec ${cfg.launcher} --etc ${config.build.installationDir}/etc -- ${loginInner} "$@"
  '';

  # setup-etc against the app prefix instead of /etc (which is Android's own
  # and stays untouched inside launcher sessions). Same semantics as NoD's
  # setup-etc.sh, rooted at a configurable directory.
  etcScript = pkgs.writeScript "nns-setup-etc" /* bash */ ''
    #!${pkgs.runtimeShell}

    set -eu -o pipefail

    : "''${VERBOSE_ARG:=}"
    : "''${VERBOSE_ECHO:=true}"

    etc="${installDir}/etc"
    new_etc="${config.build.etc}/etc"
    backup_extension="''${1:-}"

    static="''${etc}/static"

    atomic_symlink() {
        local source="''${1}"
        local target="''${2}"
        local target_tmp="''${target}.tmp"

        $VERBOSE_ECHO "Atomic symlink ''${source} to ''${target}..."

        mkdir $VERBOSE_ARG -p "$(dirname "''${target_tmp}")"
        ln -sfn "''${source}" "''${target_tmp}"
        mv -T "''${target_tmp}" "''${target}"
    }

    is_static() {
        local path="''${1}"

        if [[ -L "''${path}" ]]; then
            [[ "$(readlink "''${path}")" == "''${static}"/* ]]
            return
        fi

        if [[ -d "''${path}" ]]; then
            local file
            for file in "''${path}"/*; do
                is_static "''${file}" || return
            done
        fi

        false
    }

    rm $VERBOSE_ARG -f "''${etc}/static"
    atomic_symlink "''${new_etc}" "''${static}"

    for name in $(find "''${new_etc}/" -type l | sed -e "s,^''${new_etc}/,," ); do
        target="''${etc}/''${name}"

        mkdir $VERBOSE_ARG -p "$(dirname "''${target}")"

        if [[ -e "''${target}" ]] && ! is_static "''${target}"; then
            if [[ -n "''${backup_extension}" ]]; then
                echo "Backing up ''${target} to ''${target}''${backup_extension}..."
                cp "''${target}" "''${target}''${backup_extension}"
                atomic_symlink "''${static}/''${name}" "''${target}"
            else
                echo "Linking of ''${target} failed. Please remove this file."
            fi
        else
            atomic_symlink "''${static}/''${name}" "''${target}"
        fi
    done
  '';

  # Package installation into the app-owned profile. The stock default
  # (per-user profiles under the root-owned profiles dir) does not fit an
  # NNS store, where apps cannot create per-user directories.
  installPackagesStep = /* bash */ ''
    if [[ -e "''${HOME}/.nix-profile/manifest.json" ]]; then
      nix_previous="$(command -v nix)"

      nix profile --profile "''${HOME}/.nix-profile" list \
        | grep 'nix-on-droid-path$' \
        | cut -d ' ' -f 4 \
        | xargs -t $DRY_RUN_CMD nix profile --profile "''${HOME}/.nix-profile" remove $VERBOSE_ARG

      $DRY_RUN_CMD $nix_previous profile --profile "''${HOME}/.nix-profile" install ${config.environment.path}

      unset nix_previous
    else
      $DRY_RUN_CMD nix-env --profile "''${HOME}/.nix-profile" --install ${config.environment.path}
    fi
  '';

  # From NoD's terminal.nix: the generated colors.properties, when the user
  # configures terminal colors.
  colorsPath =
    if config.terminal.colors != { }
    then "${pkgs.writeTextFile {
      name = "colors.properties";
      text = lib.generators.toKeyValue { } config.terminal.colors;
    }}"
    else "";

  # ---- nns.services: declarative runit services supervised at boot ----

  # State lives in DE space: service dirs are materialized by activation
  # (app uid), readiness markers are boot-reset, runsvdir is started by the
  # KSU service stage inside a launcher namespace (so run scripts see /nix).
  servicesRoot = "/data/nix/var/nns";
  servicesDir = "${servicesRoot}/services";
  readyDir = "${servicesRoot}/ready";
  sshdStateDir = "/data/nix/var/sshd";

  sshdCfg = cfg.services.sshd;

  # The single wait implementation; service run scripts get one line each.
  waitBin = pkgs.writeScript "nns-wait" /* bash */ ''
    #!/system/bin/sh
    # usage: nns-wait marker <name>  - block until ready/<name> exists
    #        nns-wait up <dir>       - block until runsv reports <dir> running
    case "$1" in
      marker)
        until [ -e "${readyDir}/$2" ]; do sleep 1; done
        ;;
      up)
        until sv status "$2" 2>/dev/null | grep -q '^run:'; do sleep 1; done
        ;;
      *)
        echo "usage: nns-wait marker <name> | nns-wait up <service-dir>" >&2
        exit 2
        ;;
    esac
  '';

  servicePreamble = /* bash */ ''
    #!/system/bin/sh
    # Generated by NNS (nns.services); DO NOT EDIT.
    export HOME=/data/nix/home
    export TMPDIR=/data/nix/tmp
    export NIX_CONF_DIR=/nix/etc/nix
    export PATH=/data/nix/var/nns/bin:/nix/var/nix/profiles/profile/bin:${config.user.home}/.nix-profile/bin:/system/bin:/system/xbin
  '';

  # nns.startAt = "unlock" gates on the provider's marker; nns.after waits until
  # runsv reports the named services up. The polling loop itself lives only
  # in waitBin (marker mode) and the nns-unlock-ready provider.
  renderWaits =
    svc:
    concatMapStringsSep "\n" (w: "${waitBin} ${w}") (
      optional (svc.nns.startAt == "unlock") "marker unlock"
      ++ map (d: "up ${lib.escapeShellArg "${servicesDir}/${d}"}") svc.nns.after
    );

  mkRunScript =
    name: svc:
    let
      waits = renderWaits svc;
      exports = lib.concatStringsSep "\n" (lib.mapAttrsToList (key: value:
        if value == null then "unset ${key}"
        else "export ${key}=${lib.escapeShellArg value}"
      ) svc.process.environment);
    in
    pkgs.writeScript "nns-run-${name}" (
      servicePreamble
      + waits + lib.optionalString (waits != "") "\n"
      + exports + lib.optionalString (exports != "") "\n"
      + "exec ${lib.escapeShellArgs svc.process.argv}\n"
    );

  # Readiness provider for startAt = "unlock": the one and only process that
  # polls for CE; every gated service blocks on the marker it drops, then it
  # parks (stays "up" so runsv does not restart it into a poll loop).
  unlockReadyRun = pkgs.writeScript "nns-run-nns-unlock-ready" /* bash */ ''
    #!/system/bin/sh
    # Generated by NNS (nns.services); DO NOT EDIT.
    until [ "$(/system/bin/getprop sys.user.0.ce_available)" = "true" ]; do
      sleep 5
    done
    mkdir -p ${readyDir}
    touch ${readyDir}/unlock
    exec /system/bin/sleep 2147483647
  '';

  sshdConfig = pkgs.writeText "nns-sshd_config" /* ssh-config */ ''
    Port ${toString sshdCfg.port}
    ListenAddress ${sshdCfg.listenAddress}

    HostKey ${sshdStateDir}/ssh_host_ed25519_key
    AuthorizedKeysFile ${sshdStateDir}/authorized_keys ${config.user.home}/.ssh/authorized_keys
    PidFile ${sshdStateDir}/sshd.pid

    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    ChallengeResponseAuthentication no
    UsePAM no

    PermitRootLogin no
    PrintMotd no
    PrintLastLog no
    # Android's /data is771 system:system by platform design and every
    # key path lives under it; StrictModes would reject the ancestor on
    # ownership before ever seeing our state dir. Termux precedent.
    # The state dir itself keeps700/600 DAC, which is what matters here.
    StrictModes no

    # Non-login ssh commands never source profile.d; without this, nix falls
    # into single-user mode against the root-owned db (big-lock denied).
    SetEnv "NIX_REMOTE=daemon"

    ${sshdCfg.extraConfig}
  '';

  # sshd must stay in the foreground (-D) or runsv races its daemonizing
  # parent exit into a restart storm. Privsep chroot: OpenSSH >= 9.8 helpers
  # hardcode /var/empty, which cannot exist (rootfs is sb-ro); patched copies
  # in the DE state dir are bind-mounted over the store originals inside this
  # mount namespace only - the store stays pristine.
  sshdRun = pkgs.writeScript "nns-run-sshd" (
    servicePreamble + /* bash */ ''
      mkdir -p ${sshdStateDir} /data/nix/tmp
      if [ ! -f ${sshdStateDir}/ssh_host_ed25519_key ]; then
        ssh-keygen -t ed25519 -N "" -f ${sshdStateDir}/ssh_host_ed25519_key
        chown 10578:10578 ${sshdStateDir}/ssh_host_ed25519_key* || true
      fi

      for f in $(${lib.getExe' pkgs.gnugrep "grep"} -rl -a /var/empty ${pkgs.openssh} 2>/dev/null); do
        b=$(${lib.getExe' pkgs.coreutils "basename"} "$f")
        [ -f ${sshdStateDir}/bin/"$b"-ve ] || continue
        /system/bin/mount --bind ${sshdStateDir}/bin/"$b"-ve "$f" || true
      done

      exec ${lib.getExe' pkgs.openssh "sshd"} -D -E ${sshdStateDir}/sshd.log -f ${sshdStateDir}/sshd_config
    ''
  );

  # One-time-per-activation build of the patched helper copies (app uid writes
  # into the app-owned state dir; offsets are found at runtime because they
  # shift with every openssh bump). Sources are read through the physical
  # /data/nix/store path: activation runs inside the ssh session's namespace,
  # where a supervised sshd has already bind-mounted the patched copies over
  # /nix/store - grepping there finds nothing to patch. The grep pipeline is
  # masked: under pipefail a no-match (exit 1) would otherwise abort the
  # assignment itself before the -n guard could skip.
  patchPrivsepStep = /* bash */ ''
    $DRY_RUN_CMD mkdir -p ${sshdStateDir}/bin
    for src in ${lib.getExe' pkgs.openssh "sshd"} ${pkgs.openssh}/libexec/sshd-auth; do
      hostsrc="/data$src"
      if [ -e "$hostsrc" ]; then
        b="$(${lib.getExe' pkgs.coreutils "basename"} "$src")"
        off="$(${lib.getExe' pkgs.gnugrep "grep"} -abo /var/empty "$hostsrc" | ${lib.getExe' pkgs.coreutils "head"} -n 1 | ${lib.getExe' pkgs.coreutils "cut"} -d: -f 1 || true)"
        if [ -n "$off" ]; then
          tmp="${sshdStateDir}/bin/$b-ve.tmp"
          # A prior failed run leaves a555 copy behind (cp inherits the
          # store mode) that this uid can no longer open for write - clear
          # it first; failures must be self-cleaning.
          $DRY_RUN_CMD rm -f "$tmp"
          $DRY_RUN_CMD ${lib.getExe' pkgs.coreutils "cp"} "$hostsrc" "$tmp"
          # cp inherits the store's555 mode; without u+w, dd (running as
          # the activation uid, not root) cannot open its own copy for
          # write - EACCES that root test runs never showed.
          $DRY_RUN_CMD ${lib.getExe' pkgs.coreutils "chmod"} u+w "$tmp"
          printf '/data/ve\0\0' | $DRY_RUN_CMD ${lib.getExe' pkgs.coreutils "dd"} of="$tmp" bs=1 seek="$off" conv=notrunc
          # A silently unpatched copy would bind-mount over the store and
          # fail at every connection (chroot /var/empty); assert loudly.
          if ${lib.getExe' pkgs.gnugrep "grep"} -q /var/empty "$tmp"; then
            echo "nns: privsep patch failed for $b" >&2
            exit 1
          fi
          $DRY_RUN_CMD ${lib.getExe' pkgs.coreutils "chmod"} 755 "$tmp"
          $DRY_RUN_CMD ${lib.getExe' pkgs.coreutils "mv"} -f "$tmp" "${sshdStateDir}/bin/$b-ve"
        fi
      fi
    done
  '';

in

{

  ###### interface

  options = {

    nns = {
      enable = mkEnableOption ''
        NNS launcher-based sessions. Replaces proot: sessions run in private
        user+mount namespaces over the root-owned NNS store, and all store and
        profile writes go through the root nix daemon.
      '';

      launcher = mkOption {
        type = types.str;
        default = "/data/nix/bin/nix-enter";
        description = ''
          Path to the static NNS launcher, visible to the app on the host
          filesystem (outside the store namespace).
        '';
      };

      services = {
        enable = mkEnableOption ''
          declarative nns services: runsvdir (runit) is started from the KSU
          service stage inside a launcher namespace and supervises service
          directories that activation materializes into
          /data/nix/var/nns/services (DE space, so they exist before first
          unlock). The supervisor starts at boot; new or changed services
          take effect on the next boot (or the next manual run of the
          module's service.sh).
        '';

        services = mkOption {
          default = { };
          type = types.attrsOf serviceSubmodule;
          description = ''
            Portable modular services supervised by runit. Use `imports` to
            reuse nixpkgs service modules and `process.argv` and
            `process.environment` to configure the process. `nns.startAt`
            and `nns.after` control NNS-specific boot ordering. `nns.enable`
            disables a service. Systemd units, nested services, reload commands
            and configData are not supported.
          '';
        };

        sshd = {
          enable = mkEnableOption ''
            the sshd service: config is rendered from these options into the
            DE state dir (symlink into the closure), keys are generated on
            first run, supervision comes from runsvdir (-D foreground).
          '';

          port = mkOption {
            type = types.port;
            default = 8022;
            description = "Port to listen on.";
          };

          listenAddress = mkOption {
            type = types.str;
            default = "0.0.0.0";
            description = "Address to bind.";
          };

          extraConfig = mkOption {
            type = types.lines;
            default = "";
            description = "Extra sshd_config lines appended verbatim.";
          };
        };
      };
    };

  };

  config = mkIf cfg.enable {

    assertions = lib.concatLists (lib.mapAttrsToList (name: service:
      portableServices.getAssertions [ "nns" "services" "services" name ] service ++ [
        {
          assertion = builtins.match "[A-Za-z0-9_-]+" name != null
            && name != "sshd" && name != "nns-unlock-ready";
          message = "nns.services.services.${name}: invalid or reserved runit service name";
        }
        {
          assertion = lib.all (key: builtins.match "[A-Za-z_][A-Za-z0-9_]*" key != null)
            (attrNames service.process.environment);
          message = "nns.services.services.${name}: invalid environment variable name";
        }
        {
          assertion = !service.nns.enable || service.process.argv != [ ];
          message = "nns.services.services.${name}: process.argv must name an executable";
        }
        {
          assertion = service.configData == { } && service.services == { }
            && service.process.reloadCommand == null
            && !service.notificationProtocol.systemd && !service.notificationProtocol.s6;
          message = "nns.services.services.${name}: configData, nested services, reload and notification protocols are not supported by NNS runit";
        }
      ]) cfg.services.services);
    warnings = lib.concatLists (lib.mapAttrsToList (name: service:
      portableServices.getWarnings [ "nns" "services" "services" name ] service
    ) cfg.services.services);

    # runsvdir/sv/pause for nns.services; also what nns-wait's `up` mode
    # shells out to (rendered run scripts put the profile bin on PATH).
    # AVF guests reach the phone's nix daemon through this bridge: the
    # guest's plain daemon socket tunnels over vsock to `nix-daemon --stdio`,
    # so guest nix works with NIX_REMOTE=daemon and no config changes. The
    # launcher preamble supplies NIX_CONF_DIR and the /nix store namespace.
    nns.services.services.nix-bridge = mkIf cfg.services.enable {
      process.argv = [
        "${lib.getExe pkgs.socat}"
        "VSOCK-LISTEN:15555,fork"
        "SYSTEM:/nix/var/nix/profiles/default/bin/nix-daemon --stdio"
      ];
    };

    environment.packages = lib.optional cfg.services.enable pkgs.runit;

    environment.sessionVariables.NIX_SSL_CERT_FILE =
      "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

    # The activation options are `types.attrs`, whose merge does not respect
    # priorities for sub-attribute definitions — a `mkForce` on an individual
    # key silently loses. Overrides must therefore replace the whole option
    # value, which means replicating the steps other modules contribute
    # (home-manager's priority fixup; upgrade's dev/shm bootstrap).
    build = lib.optionalAttrs (options ? build && options.build ? linkProotStatic) {
      linkProotStatic = mkForce false;
    } // {
      activationBefore = mkForce ({
        # /bin/sh and /usr/bin/env live in the app prefix now; launcher
        # sessions see the real Android root and the store, not a proot tree.
        linkBinSh = /* bash */ ''
          $DRY_RUN_CMD mkdir $VERBOSE_ARG --parents ${installDir}/bin
          $DRY_RUN_CMD ln $VERBOSE_ARG --symbolic --force ${config.environment.binSh} ${installDir}/bin/.sh.tmp
          $DRY_RUN_CMD mv $VERBOSE_ARG ${installDir}/bin/.sh.tmp ${installDir}/bin/sh
        '';

        linkUsrBinEnv = /* bash */ ''
          $DRY_RUN_CMD mkdir $VERBOSE_ARG --parents ${installDir}/usr/bin
          $DRY_RUN_CMD ln $VERBOSE_ARG --symbolic --force ${config.environment.usrBinEnv} ${installDir}/usr/bin/.env.tmp
          $DRY_RUN_CMD mv $VERBOSE_ARG ${installDir}/usr/bin/.env.tmp ${installDir}/usr/bin/env
        '';
      } // lib.optionalAttrs (config.home-manager.config != null && config.home-manager.useUserPackages) {
        setPriorityHomeManagerPath = /* bash */ ''
          if nix-env -q | grep '^home-manager-path$'; then
            $DRY_RUN_CMD nix-env $VERBOSE_ARG --set-flag priority 120 home-manager-path
          fi
        '';
      });

      activation = mkForce ({
        installLogin = /* bash */ ''
          if ! diff ${installDir}/bin/login ${login} > /dev/null; then
            $DRY_RUN_CMD mkdir $VERBOSE_ARG --parents ${installDir}/bin
            $DRY_RUN_CMD cp $VERBOSE_ARG ${login} ${installDir}/bin/.login.tmp
            $DRY_RUN_CMD chmod $VERBOSE_ARG u+w ${installDir}/bin/.login.tmp
            $DRY_RUN_CMD mv $VERBOSE_ARG ${installDir}/bin/.login.tmp ${installDir}/bin/login
          fi
        '';

        installLoginInner = /* bash */ ''
          if (test -e ${installDir}/usr/lib/.login-inner.new && ! diff ${installDir}/usr/lib/.login-inner.new ${loginInner} > /dev/null) || \
              (! test -e ${installDir}/usr/lib/.login-inner.new && ! diff ${installDir}/usr/lib/login-inner ${loginInner} > /dev/null); then
            $DRY_RUN_CMD mkdir $VERBOSE_ARG --parents ${installDir}/usr/lib
            $DRY_RUN_CMD cp $VERBOSE_ARG ${loginInner} ${installDir}/usr/lib/.login-inner.tmp
            $DRY_RUN_CMD chmod $VERBOSE_ARG u+w ${installDir}/usr/lib/.login-inner.tmp
            $DRY_RUN_CMD mv $VERBOSE_ARG ${installDir}/usr/lib/.login-inner.tmp ${installDir}/usr/lib/.login-inner.new
          fi
        '';

        # Sessions do not use proot; nothing to install.
        installProotStatic = "";

        setUpEtc = /* bash */ ''
          $DRY_RUN_CMD bash ${etcScript} \
            ${toString config.environment.etcBackupExtension}
        '';

        installPackages = installPackagesStep;

        # From NoD's upgrade.nix (stateVersion < 21.11 bootstrap);
        # harmless when unnecessary.
        createDevShm = /* bash */ ''
          $DRY_RUN_CMD mkdir $VERBOSE_ARG --parents ${installDir}/dev/shm
        '';
      } // lib.optionalAttrs (config.terminal.font != null) {
        # The Android terminal UI runs outside the launcher's mount namespace,
        # so its font symlink must resolve within app-owned storage, not /nix.
        linkFont = /* bash */ ''
          $DRY_RUN_CMD mkdir $VERBOSE_ARG -p "${config.user.home}/.termux"
          if [ -e "${config.user.home}/.termux/font.ttf" ] && ! [ -L "${config.user.home}/.termux/font.ttf" ]; then
            $DRY_RUN_CMD mv $VERBOSE_ARG "${config.user.home}/.termux/font.ttf" \
              "${config.user.home}/.termux/font.ttf.bak"
          fi
          if [ ! -e "${config.user.home}/.termux/nns-font.ttf" ]; then
            $DRY_RUN_CMD cp $VERBOSE_ARG "${config.terminal.font}" \
              "${config.user.home}/.termux/nns-font.ttf"
          elif ! cmp -s "${config.terminal.font}" "${config.user.home}/.termux/nns-font.ttf"; then
            $DRY_RUN_CMD chmod $VERBOSE_ARG u+w "${config.user.home}/.termux/nns-font.ttf"
            $DRY_RUN_CMD cp $VERBOSE_ARG "${config.terminal.font}" \
              "${config.user.home}/.termux/nns-font.ttf"
            $DRY_RUN_CMD chmod $VERBOSE_ARG u-w "${config.user.home}/.termux/nns-font.ttf"
          fi
          if [ "$(readlink "${config.user.home}/.termux/font.ttf")" != "${config.user.home}/.termux/nns-font.ttf" ]; then
            $DRY_RUN_CMD ln $VERBOSE_ARG -sf "${config.user.home}/.termux/nns-font.ttf" \
              "${config.user.home}/.termux/font.ttf"
          fi
        '';
      } // lib.optionalAttrs (config.terminal.colors != { }) {
        linkColors = /* bash */ ''
          $DRY_RUN_CMD mkdir $VERBOSE_ARG -p "${config.user.home}/.termux"
          if [ -e "${config.user.home}/.termux/colors.properties" ] && ! [ -L "${config.user.home}/.termux/colors.properties" ]; then
            $DRY_RUN_CMD mv $VERBOSE_ARG "${config.user.home}/.termux/colors.properties" \
              "${config.user.home}/.termux/colors.properties.bak"
          fi
          $DRY_RUN_CMD ln $VERBOSE_ARG -sf "${colorsPath}" \
            "${config.user.home}/.termux/colors.properties"
        '';
      } // (lib.optionalAttrs (config.terminal.font == null) {
        unlinkFont = /* bash */ ''
          if [ -L "${config.user.home}/.termux/font.ttf" ]; then
            if [ "$(readlink "${config.user.home}/.termux/font.ttf")" = "${config.user.home}/.termux/nns-font.ttf" ]; then
              $DRY_RUN_CMD rm $VERBOSE_ARG -f "${config.user.home}/.termux/nns-font.ttf"
            fi
            $DRY_RUN_CMD rm $VERBOSE_ARG "${config.user.home}/.termux/font.ttf"
          fi
        '';
      }) // (lib.optionalAttrs (config.terminal.colors == { }) {
        unlinkColors = /* bash */ ''
          if [ -e "${config.user.home}/.termux/colors.properties" ] && [ -L "${config.user.home}/.termux/colors.properties" ]; then
            $DRY_RUN_CMD rm $VERBOSE_ARG "${config.user.home}/.termux/colors.properties"
          fi
        '';
      }) // lib.optionalAttrs (cfg.services.enable) {
        # Materialize service run scripts as symlinks into the closure (dry-run
        # friendly, atomic replaces) and render sshd's config the same way.
        # No interaction with a live runsvdir: run scripts are read at each
        # (re)start, and the supervisor picks the directory set up on its next
        # start (boot, or a manual service.sh run).
        materializeServices = /* bash */ ''
          # runit's tools live in DE space: environment.packages installs into
          # HOME/.nix-profile, which is credential-encrypted and invisible at
          # boot - the supervisor and nns-wait's `sv` need these before first
          # unlock. Copied from the closure, so the phone's own nixpkgs builds
          # them.
          $DRY_RUN_CMD mkdir -p ${servicesRoot}/bin
          $DRY_RUN_CMD cp -f ${lib.pipe ["runsvdir" "runsv" "sv"] [(lib.map (lib.getExe' pkgs.runit)) lib.escapeShellArgs]} ${servicesRoot}/bin/
          $DRY_RUN_CMD mkdir -p ${servicesDir}/nns-unlock-ready
          $DRY_RUN_CMD ln -sfn ${unlockReadyRun} ${servicesDir}/nns-unlock-ready/run
          ${lib.concatMapStrings (name:
            let
              svc = cfg.services.services.${name};
            in
            lib.optionalString svc.nns.enable /* bash */ ''
              $DRY_RUN_CMD mkdir -p ${servicesDir}/${name}
              $DRY_RUN_CMD ln -sfn ${mkRunScript name svc} ${servicesDir}/${name}/run
            '')
            (attrNames cfg.services.services)}
          ${lib.concatMapStrings (name:
            lib.optionalString (! cfg.services.services.${name}.nns.enable) /* bash */ ''
              $DRY_RUN_CMD rm -rf ${servicesDir}/${name}
            '')
            (attrNames cfg.services.services)}
          ${lib.optionalString sshdCfg.enable /* bash */ ''
            $DRY_RUN_CMD mkdir -p ${servicesDir}/sshd
            $DRY_RUN_CMD ln -sfn ${sshdRun} ${servicesDir}/sshd/run
            $DRY_RUN_CMD ln -sfn ${sshdConfig} ${sshdStateDir}/sshd_config
            ${patchPrivsepStep}
            # DE mirror of the user's authorized_keys: activation only ever
            # runs post-unlock (deploy needs CE for its profile anyway), and
            # sessions resolve the DE copy first, home as fallback.
            if [ -e ${config.user.home}/.ssh/authorized_keys ]; then
              $DRY_RUN_CMD cp -f ${config.user.home}/.ssh/authorized_keys ${sshdStateDir}/authorized_keys
            fi
          ''}
        '';
      });
    };

  };

}
