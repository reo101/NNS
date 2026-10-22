{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config;
  nixTrustedGroupGid = 30000;
  accountRecords = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: account:
      "${name}:x:${builtins.toString account.uid}:${builtins.toString account.gid}:${name}:${account.home}:${account.shell}"
    ) cfg.accounts
  );
  callerAccounts = pkgs.writeTextDir "etc/nns/passwd" (accountRecords + "\n");
  reservedVariables = [
    "HOME"
    "USER"
    "LOGNAME"
    "PATH"
    "ENV"
    "BASH_ENV"
    "NNS_PROFILE"
    "NIX_REMOTE"
    "NIX_CONF_DIR"
  ];
  validName = name: builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" name != null;
  validVariable = name: builtins.match "[A-Za-z_][A-Za-z0-9_]*" name != null;
  profileVariables = lib.mapAttrs (
    name: profile:
    pkgs.writeTextFile {
      name = "nns-environment-${name}";
      destination = "/etc/nns/environment";
      text =
        let
          variables = {
            SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
            NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          }
          // profile.variables;
        in
        lib.concatMapStrings (key: "export ${key}=${lib.escapeShellArg variables.${key}}\n") (
          builtins.attrNames variables
        );
    }
  ) cfg.environment.profiles;
  profiles = lib.mapAttrs (
    name: profile:
    pkgs.buildEnv {
      name = "nns-environment-${name}";
      paths = profile.packages ++ [ profileVariables.${name} ];
      postBuild = ''mkdir -p "$out/bin"'';
    }
  ) cfg.environment.profiles;
  infrastructure = import ../system-profile.nix {
    phonePkgs = pkgs;
    nixPackage = cfg.nix.package;
    extraPaths = [
      callerAccounts
      pkgs.util-linux
      pkgs.openssh
      pkgs.cacert
    ];
  };
  state = cfg.system.stateDirectory;
  etcDirectory = cfg.system.etcDirectory;
  profileDirectory = cfg.system.profileDirectory;
  serviceLib = import "${pkgs.path}/lib/services/lib.nix" { inherit lib; };
  hasEnvironment =
    (lib.evalModules {
      class = "service";
      modules = [ (import "${pkgs.path}/lib/services/service.nix" { inherit pkgs; }) ];
    }).options.process
      ? environment;
  serviceType =
    (serviceLib.configure {
      serviceManagerPkgs = pkgs;
      extraRootModules = [
        ({ name, ... }: {
          options = {
            process = lib.optionalAttrs (!hasEnvironment) {
              environment = mkOption {
                type = types.lazyAttrsOf (
                  types.nullOr (types.coercedTo (types.either types.path types.package) (value: "${value}") types.str)
                );
                default = { };
              };
            };
            nns = {
              enable = mkOption {
                type = types.bool;
                default = true;
              };
              startAt = mkOption {
                type = types.enum [
                  "boot"
                  "unlock"
                ];
                default = "boot";
              };
              after = mkOption {
                type = types.listOf types.str;
                default = [ ];
              };
            };
          };
        })
      ];
    }).serviceSubmodule;
  enabledServices = lib.filterAttrs (_: service: service.nns.enable) cfg.services.runit;
  renderService =
    name: service:
    pkgs.writeScript "nns-service-${name}" ''
      #!${pkgs.runtimeShell}
      set -eu
      ${lib.optionalString (name == "nix-daemon") "# Configuration dependency: ${etc}"}
      ${lib.optionalString (name == "sshd") "# Configuration dependency: ${sshdConfig}"}
      export PATH=${lib.escapeShellArg "${infrastructure}/bin:/system/bin:/system/xbin"}
      export HOME=${lib.escapeShellArg cfg.accounts.root.home}
      export TMPDIR=/data/nix/tmp
      export NIX_CONF_DIR=${lib.escapeShellArg cfg.system.nixConfDirectory}
      ${lib.optionalString (service.nns.startAt == "unlock") ''
        until [ "$(/system/bin/getprop sys.user.0.ce_available)" = true ]; do sleep 5; done
      ''}
      ${lib.concatMapStrings (dependency: ''
        until sv status ${lib.escapeShellArg "${state}/services/${dependency}"} 2>/dev/null | grep -q '^run:'; do sleep 1; done
      '') service.nns.after}
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          key: value: if value == null then "unset ${key}" else "export ${key}=${lib.escapeShellArg value}"
        ) service.process.environment
      )}
      exec ${lib.escapeShellArgs service.process.argv}
    '';
  keyFiles = lib.mapAttrs (
    name: account:
    pkgs.writeText "nns-authorized-keys-${name}" (
      lib.concatStringsSep "\n" (
        if name == "root" then cfg.services.openssh.authorizedRootKeys else account.publicKeys
      )
      + "\n"
    )
  ) cfg.accounts;
  authorizedKeys = pkgs.writeShellScript "nns-authorized-keys" ''
    set -eu
    case "''${1:-}" in
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: account: ''
        ${name})
          ${pkgs.coreutils}/bin/cat ${keyFiles.${name}}
          ${lib.concatMapStrings (file: ''
            if [ -f ${lib.escapeShellArg file} ]; then
              ${pkgs.util-linux}/bin/setpriv --reuid ${toString account.uid} --regid ${toString account.gid} --clear-groups \
                ${pkgs.coreutils}/bin/cat ${lib.escapeShellArg file}
            fi
          '') account.authorizedKeysFiles}
          ;;
      '') cfg.accounts
    )}
      *) exit 1 ;;
    esac
  '';
  sshdConfig = pkgs.writeText "nns-sshd-config" ''
    Port ${toString cfg.services.openssh.port}
    HostKey ${state}/ssh_host_ed25519_key
    PidFile ${state}/sshd.pid
    PermitRootLogin prohibit-password
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    UsePAM no
    StrictModes yes
    PermitUserEnvironment no
    PermitUserRC no
    AllowAgentForwarding no
    AllowTcpForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    AuthorizedKeysFile none
    AuthorizedKeysCommand ${authorizedKeys} %u
    AuthorizedKeysCommandUser root
    Subsystem sftp ${pkgs.openssh}/libexec/sftp-server
    SetEnv NIX_REMOTE=daemon NIX_CONF_DIR=${cfg.system.nixConfDirectory} PATH=${infrastructure}/bin:/system/bin:/system/xbin
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: account: ''
        Match User ${name}
          SetEnv NIX_REMOTE=daemon NIX_CONF_DIR=${cfg.system.nixConfDirectory} PATH=/data/nix/var/nns/bin:${infrastructure}/bin:${account.home}/.nix-profile/bin:/system/bin:/system/xbin
      '') (lib.filterAttrs (name: _: name != "root" && name != "sshd") cfg.accounts)
    )}
    Match all
    ${cfg.services.openssh.extraConfig}
  '';
  checkSshd = pkgs.writeShellScript "nns-check-sshd" ''
    exec ${cfg.system.launcher} --etc "$1" -- ${pkgs.openssh}/bin/sshd -t -f "$2"
  '';
  etc = pkgs.runCommand "nns-system-etc" { } ''
    mkdir -p "$out/nix" "$out/ssl/certs"
    cat > "$out/passwd" <<'EOF'
    ${accountRecords}
    EOF
    cat > "$out/group" <<'EOF'
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: account: "${name}:x:${toString account.gid}:${name}") cfg.accounts
    )}
    nix-trusted:x:${builtins.toString nixTrustedGroupGid}:${
      lib.concatStringsSep "," (
        builtins.attrNames (lib.filterAttrs (_: account: account.nixTrusted) cfg.accounts)
      )
    }
    EOF
    cat > "$out/nix/nix.conf" <<'EOF'
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        key: value:
        "${key} = ${
          if builtins.isBool value then
            lib.boolToString value
          else if builtins.isList value then
            lib.concatStringsSep " " value
          else
            toString value
        }"
      ) cfg.nix.settings
    )}
    EOF
    printf '%s\n' 'nameserver 1.1.1.1' > "$out/resolv.conf"
    ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt "$out/ssl/certs/ca-certificates.crt"
  '';
  generation = pkgs.runCommand "nns-system-generation" { } ''
    mkdir -p "$out/profiles" "$out/services" "$out/authorized_keys"
    ln -s ${infrastructure} "$out/system-profile"
    ln -s ${etc} "$out/etc"
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: profile: ''ln -s ${profile} "$out/profiles/${name}"'') profiles
    )}
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: service: ''
        mkdir -p "$out/services/${name}"
        ln -s ${renderService name service} "$out/services/${name}/run"
      '') enabledServices
    )}
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: file: ''ln -s ${file} "$out/authorized_keys/${name}"'') keyFiles
    )}
    ${lib.optionalString cfg.services.openssh.enable ''
      touch "$out/sshd-enabled"
      ln -s ${sshdConfig} "$out/sshd_config"
      ln -s ${checkSshd} "$out/check-sshd"
    ''}
    cat > "$out/activate" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    generation=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
    export PATH="$generation/system-profile/bin:/system/bin:/system/xbin"
    export NNS_STATE_DIRECTORY=${lib.escapeShellArg state}
    export NNS_ETC_DIRECTORY=${lib.escapeShellArg etcDirectory}
    export NNS_PROFILE_DIRECTORY=${lib.escapeShellArg profileDirectory}
    export NNS_NIX_CONF_DIRECTORY=${lib.escapeShellArg cfg.system.nixConfDirectory}
    export NNS_LAUNCHER=${lib.escapeShellArg cfg.system.launcher}
    exec ${pkgs.runtimeShell} ${./activate.sh} "$generation" "''${1:-switch}"
    EOF
    chmod 755 "$out/activate"
  '';
in
{
  _class = "nns";
  options = {
    assertions = mkOption {
      type = types.listOf types.unspecified;
      default = [ ];
      internal = true;
    };
    nix.package = mkOption {
      type = types.package;
      default = pkgs.nix;
      defaultText = lib.literalExpression "pkgs.nix";
      description = "Nix package for the daemon and administrative system profile.";
    };
    nix.settings = mkOption {
      type = types.attrsOf (
        types.oneOf [
          types.str
          (types.listOf types.str)
          types.bool
          types.int
        ]
      );
      default = { };
      description = "Administrative daemon configuration. Build isolation remains deferred.";
    };
    system = {
      build.toplevel = mkOption {
        type = types.package;
        readOnly = true;
      };
      stateDirectory = mkOption {
        type = types.str;
        default = "/data/nix/var/nns";
      };
      etcDirectory = mkOption {
        type = types.str;
        default = "/data/nix/var/daemon-etc";
      };
      profileDirectory = mkOption {
        type = types.str;
        default = "/nix/var/nix/profiles";
      };
      nixConfDirectory = mkOption {
        type = types.str;
        default = "/data/nix/etc/nix";
      };
      launcher = mkOption {
        type = types.str;
        default = "/data/nix/bin/nix-enter";
      };
    };
    environment.profiles = mkOption {
      default = { };
      type = types.attrsOf (
        types.submodule (
          { ... }: {
            options = {
              packages = mkOption {
                type = types.listOf types.package;
                default = [ ];
              };
              variables = mkOption {
                type = types.attrsOf types.str;
                default = { };
              };
            };
          }
        )
      );
    };
    services.runit = mkOption {
      default = { };
      type = types.attrsOf serviceType;
    };
    services.openssh = mkOption {
      default = { };
      type = types.submodule (
        { ... }: {
          options = {
            enable = mkOption {
              type = types.bool;
              default = false;
            };
            port = mkOption {
              type = types.port;
              default = 8022;
            };
            authorizedRootKeys = mkOption {
              type = types.listOf types.str;
              default = [ ];
            };
            extraConfig = mkOption {
              type = types.lines;
              default = "";
            };
          };
        }
      );
    };
    accounts = mkOption {
      default = { };
      description = "Daemon-side Unix account records for existing UIDs, not Android account creation.";
      type = types.attrsOf (
        types.submodule (
          { ... }: {
            options = {
              uid = mkOption { type = types.ints.between 0 4294967294; };
              gid = mkOption { type = types.ints.between 0 4294967294; };
              nixTrusted = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Grant Nix daemon administration privileges through the virtual
                  nix-trusted group. This does not control store-read access.
                  UID 0 remains trusted independently of this flag.
                '';
              };
              home = mkOption { type = types.str; };
              shell = mkOption {
                type = types.str;
                default = "${pkgs.bashInteractive}/bin/bash";
              };
              publicKeys = mkOption {
                type = types.listOf types.str;
                default = [ ];
              };
              authorizedKeysFiles = mkOption {
                type = types.listOf types.str;
                default = [ ];
              };
            };
          }
        )
      );
    };
  };
  config = {
    nix.settings = lib.mapAttrs (_: lib.mkDefault) {
      build-users-group = "";
      sandbox = false;
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [
        "root"
        "@nix-trusted"
      ];
      ssl-cert-file = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };
    accounts.root = {
      uid = 0;
      gid = 0;
      home = lib.mkDefault "${state}/root";
    };
    # Android's documented nobody identity, not an allocated application UID.
    accounts.sshd = lib.mkIf cfg.services.openssh.enable {
      uid = 9999;
      gid = 9999;
      home = "/var/empty";
      shell = "/system/bin/false";
    };
    system.build.toplevel = generation;
    services.runit = {
      nix-daemon.process = {
        argv = [ "${cfg.nix.package}/bin/nix-daemon" ];
        environment.NIX_REMOTE = "local";
      };
      sshd = lib.mkIf cfg.services.openssh.enable {
        # The supervisor already provides /nix and the staged /etc. Avoid a
        # launcher monitor here so runit sends TERM directly to the daemon.
        process.argv = [
          "${pkgs.openssh}/bin/sshd"
          "-D"
          "-e"
          "-f"
          "${state}/sshd_config"
        ];
      };
    };
    assertions =
      lib.mapAttrsToList (name: profile: {
        assertion =
          validName name
          && !(builtins.elem name [
            "nns-system"
            "system-profile"
          ])
          && builtins.match ".*-[0-9]+-link" name == null
          && builtins.all (key: validVariable key && !(builtins.elem key reservedVariables)) (
            builtins.attrNames profile.variables
          );
        message = "Invalid or reserved NNS environment name/variable: ${name}";
      }) cfg.environment.profiles
      ++ lib.mapAttrsToList (name: account: {
        assertion =
          validName name
          && name != "nix-trusted"
          && account.gid != nixTrustedGroupGid
          && (name == "root" || account.uid != 0)
          && builtins.all (value: !(lib.hasInfix "\n" value) && !(lib.hasInfix ":" value)) [
            account.home
            account.shell
          ]
          && lib.hasPrefix "/" account.home
          && lib.hasPrefix "/" account.shell;
        message = "Invalid NNS account: ${name}";
      }) cfg.accounts
      ++ lib.concatLists (
        lib.mapAttrsToList (
          name: service:
          serviceLib.getAssertions [ "services" "runit" name ] service
          ++ [
            {
              assertion =
                validName name
                && (
                  !service.nns.enable
                  || (
                    service.process.argv != [ ]
                    && (
                      lib.hasPrefix "/nix/store/" (builtins.head service.process.argv)
                      || lib.hasPrefix "/system/bin/" (builtins.head service.process.argv)
                      || builtins.head service.process.argv == cfg.system.launcher
                    )
                  )
                )
                && !(service.process.environment ? PATH)
                && builtins.all validVariable (builtins.attrNames service.process.environment)
                && builtins.all (
                  dependency: builtins.hasAttr dependency enabledServices && dependency != name
                ) service.nns.after
                && service.configData == { }
                && service.services == { }
                && service.process.reloadCommand == null
                && !service.notificationProtocol.systemd
                && !service.notificationProtocol.s6;
              message = "Invalid or unsupported NNS runit service: ${name}";
            }
          ]
        ) cfg.services.runit
      )
      ++ [
        {
          assertion =
            (lib.toposort (left: right: builtins.elem left enabledServices.${right}.nns.after) (
              builtins.attrNames enabledServices
            ))
              ? result;
          message = "NNS service ordering contains a dependency cycle";
        }
        {
          assertion = !cfg.services.openssh.enable || cfg.services.openssh.authorizedRootKeys != [ ];
          message = "NNS root SSH requires explicit administrative public keys";
        }
        {
          assertion =
            cfg.accounts.root.authorizedKeysFiles == [ ]
            &&
              builtins.length (lib.unique (map (account: account.uid) (builtins.attrValues cfg.accounts)))
              == builtins.length (builtins.attrNames cfg.accounts);
          message = "NNS accounts must have unique UIDs and root keys must be declarative";
        }
      ];
  };
}
