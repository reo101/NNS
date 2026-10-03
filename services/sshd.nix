# sshd for NNS Nix-on-Droid configurations: the supervised runit service
# (a plain nns.services.services entry, so supervision, the run-script
# preamble and the PATH contract come from the shared machinery) plus the
# activation steps that materialize its config, state and the ssh session
# environment.
#
# Import alongside the core module in a NoD configuration:
#
#   imports = [
#     inputs.nns.nixOnDroidModules.nns
#     inputs.nns.nixOnDroidModules."nns-sshd"
#   ];
#
# and enable with nns.services.sshd.enable (requires nns.services.enable).
# The service is a plain definition: a user-defined
# nns.services.services.sshd conflicts loudly instead of silently dropping
# the wrapper.
{ config, lib, pkgs, ... }:
    let
      inherit (lib) mkEnableOption mkIf mkOption types;

      cfg = config.nns.services.sshd;

      # DE space (created by post-fs-data and the wrapper alike), also home
      # of the patched privsep helpers. The module scripts stage passwd/
      # group into it and keep its directory context app-accessible.
      sshdStateDir = "/data/nix/var/sshd";

      sshdConfig = pkgs.writeText "nns-sshd_config" /* ssh-config */ ''
        Port ${builtins.toString cfg.port}
        ListenAddress ${cfg.listenAddress}

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

        # Non-login ssh commands never source profile.d; without this, nix
        # falls into single-user mode against the root-owned db (big-lock
        # denied).
        SetEnv "NIX_REMOTE=daemon"

        # sshd stamps a compiled default PATH over SetEnv, so ssh sessions
        # pick up the profile directories through PermitUserEnvironment
        # instead; without them a non-login remote command has no
        # nix-store, which breaks deploy-rs's copy phase (sh: nix-store:
        # inaccessible or not found).
        PermitUserEnvironment yes

        ${cfg.extraConfig}
      '';

      # Delivered as ~/.ssh/environment; consulted because of
      # PermitUserEnvironment. NIX_CONF_DIR keeps non-login nix invocations
      # on the shared staged config (ssl-cert-file, substituters) instead
      # of nix's compiled-in defaults; PATH is the shared session contract
      # (nns.services.sessionPath).
      sshEnvironment = pkgs.writeText "nns-ssh-environment" ''
        PATH=${config.nns.services.sessionPath}
        NIX_CONF_DIR=/data/nix/etc/nix
      '';

      # Execed by the generic run script, which already provides HOME,
      # TMPDIR, NIX_CONF_DIR and the session PATH. sshd must stay in the
      # foreground (-D) or runsv races its daemonizing parent exit into a
      # restart storm. Privsep chroot: OpenSSH >= 9.8 helpers hardcode
      # /var/empty, which cannot exist (rootfs is sb-ro); patched copies in
      # the DE state dir are bind-mounted over the store originals inside
      # this mount namespace only - the store stays pristine.
      sshdWrapper = pkgs.writeScript "nns-sshd-wrapper" /* bash */ ''
        #!/system/bin/sh
        mkdir -p ${sshdStateDir} /data/nix/tmp
        if [ ! -f ${sshdStateDir}/ssh_host_ed25519_key ]; then
          ${lib.getExe' pkgs.openssh "ssh-keygen"} -t ed25519 -N "" -f ${sshdStateDir}/ssh_host_ed25519_key
          chown ${builtins.toString config.user.uid}:${builtins.toString config.user.gid} ${sshdStateDir}/ssh_host_ed25519_key{,.pub} || true
        fi

        for f in $(${lib.getExe' pkgs.gnugrep "grep"} -rl -a /var/empty ${pkgs.openssh} 2>/dev/null); do
          b=$(${lib.getExe' pkgs.coreutils "basename"} "$f")
          [ -f ${sshdStateDir}/bin/"$b"-ve ] || continue
          /system/bin/mount --bind ${sshdStateDir}/bin/"$b"-ve "$f" || true
        done

        exec ${lib.getExe' pkgs.openssh "sshd"} -D -E ${sshdStateDir}/sshd.log -f ${sshdStateDir}/sshd_config
      '';

      # One-time-per-activation build of the patched helper copies (app uid
      # writes into the app-owned state dir; offsets are found at runtime
      # because they shift with every openssh bump). Sources are read
      # through the physical /data/nix/store path: activation runs inside
      # the ssh session's namespace, where a supervised sshd has already
      # bind-mounted the patched copies over /nix/store - grepping there
      # finds nothing to patch. The grep pipeline is masked: under pipefail
      # a no-match (exit 1) would otherwise abort the assignment itself
      # before the -n guard could skip.
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
              # store mode) that this uid can no longer open for write -
              # clear it first; failures must be self-cleaning.
              $DRY_RUN_CMD rm -f "$tmp"
              $DRY_RUN_CMD ${lib.getExe' pkgs.coreutils "cp"} "$hostsrc" "$tmp"
              # cp inherits the store's555 mode; without u+w, dd (running
              # as the activation uid, not root) cannot open its own copy
              # for write - EACCES that root test runs never showed.
              $DRY_RUN_CMD ${lib.getExe' pkgs.coreutils "chmod"} u+w "$tmp"
              printf '/data/ve\0\0' | $DRY_RUN_CMD ${lib.getExe' pkgs.coreutils "dd"} of="$tmp" bs=1 seek="$off" conv=notrunc
              # A silently unpatched copy would bind-mount over the store
              # and fail at every connection (chroot /var/empty); assert
              # loudly.
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

      options.nns.services.sshd = {
        enable = mkEnableOption ''
          the sshd service: config is rendered from these options into the
          DE state dir, keys are generated on first run, supervision comes
          from runit (nns.services.enable must also be set).
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

      config = mkIf cfg.enable {

        assertions = [
          {
            assertion = config.nns.services.enable;
            message = "nns.services.sshd requires nns.services.enable (supervision comes from the shared runit machinery)";
          }
        ];

        nns.services.services.sshd = {
          process.argv = [ "${sshdWrapper}" ];
        };

        nns.services.extraActivation.installSshd = /* bash */ ''
          $DRY_RUN_CMD ln -sfn ${sshdConfig} ${sshdStateDir}/sshd_config
          ${patchPrivsepStep}
          $DRY_RUN_CMD mkdir -p ${config.user.home}/.ssh
          $DRY_RUN_CMD cp -f ${sshEnvironment} ${config.user.home}/.ssh/environment
          $DRY_RUN_CMD chmod 600 ${config.user.home}/.ssh/environment
          # DE mirror of the user's authorized_keys: activation only ever
          # runs post-unlock (deploy needs CE for its profile anyway), and
          # sessions resolve the DE copy first, home as fallback.
          if [ -e ${config.user.home}/.ssh/authorized_keys ]; then
            $DRY_RUN_CMD cp -f ${config.user.home}/.ssh/authorized_keys ${sshdStateDir}/authorized_keys
          fi
        '';

      };

    }

