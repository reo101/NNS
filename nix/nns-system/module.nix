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
  serviceManagerDefinition = cfg.system.serviceManagers.${cfg.system.serviceManager};
  infrastructure = import ../system-profile.nix {
    phonePkgs = pkgs;
    nixPackage = cfg.nix.package;
    extraPaths = [
      callerAccounts
      pkgs.util-linux
      pkgs.openssh
      pkgs.cacert
    ]
    ++ serviceManagerDefinition.runtimePackages;
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
              type = mkOption {
                type = types.enum [
                  "longrun"
                  "oneshot"
                ];
                default = "longrun";
                description = "Supervise a persistent process or retry a finite job until it succeeds.";
              };
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
  enabledServices = lib.filterAttrs (_: service: service.nns.enable) cfg.system.services;
  renderAction =
    name: service:
    pkgs.writeShellScript "nns-service-${name}" ''
      set -eu
      exec >>${lib.escapeShellArg "${state}/supervisor.log"} 2>&1
      ${lib.optionalString (name == "nix-daemon") "# Configuration dependency: ${etc}"}
      ${lib.optionalString (name == "sshd") "# Configuration dependency: ${sshdConfig}"}
      # NNS start phase: ${service.nns.startAt}
      ${lib.concatMapStrings (
        dependency: "# NNS dependency: ${dependency} (${allServices.${dependency}.nns.type})\n"
      ) service.nns.after}
      export PATH=${lib.escapeShellArg "${infrastructure}/bin:/system/bin:/system/xbin"}
      export HOME=${lib.escapeShellArg cfg.accounts.root.home}
      export TMPDIR=/data/nix/tmp
      export NIX_CONF_DIR=${lib.escapeShellArg cfg.system.nixConfDirectory}
      cd ${lib.escapeShellArg "${state}/services/${name}"}
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          key: value: if value == null then "unset ${key}" else "export ${key}=${lib.escapeShellArg value}"
        ) service.process.environment
      )}
      ${
        if service.nns.type == "oneshot" then
          ''
            rm -f completed exit-status
            set +e
            ${lib.escapeShellArgs service.process.argv}
            status=$?
            set -e
            printf '%s\n' "$status" > ".exit-status.$$"
            mv -Tf ".exit-status.$$" exit-status
            if [ "$status" -eq 0 ]; then : > completed; fi
            exit "$status"
          ''
        else
          ''
            exec ${lib.escapeShellArgs service.process.argv}
          ''
      }
    '';
  renderFinish =
    name:
    pkgs.writeShellScript "nns-service-${name}-finish" ''
      set -eu
      printf '%s %s\n' "$1" "$2" > exit-status
      if [ "$1" = 0 ] && [ "$2" = 0 ]; then
        : > completed
        : > down
        exec ${infrastructure}/bin/sv down .
      fi
    '';
  dispatcherArgv = [
    "${pkgs.runtimeShell}"
    ./service-dispatch.sh
    cfg.system.serviceManager
    state
  ];
  allServices = enabledServices // {
    nns-dispatcher = {
      nns = {
        type = "longrun";
        startAt = "boot";
        after = [ ];
      };
      process.argv = dispatcherArgv;
      process.environment = { };
    };
  };
  serviceNames = builtins.filter (name: name != "nns-dispatcher") (builtins.attrNames allServices);
  serviceActions = lib.mapAttrs (name: service: {
    action = renderAction name service;
    finish = renderFinish name;
    oneshot = service.nns.type == "oneshot";
    inherit (service.nns) type after startAt;
  }) allServices;
  # Runit supervises the policy process from the published run tree. Native
  # managers start it from their own definitions instead.
  runTreeServices =
    if serviceManagerDefinition.render == null then
      serviceActions
    else
      lib.filterAttrs (name: _: name != "nns-dispatcher") serviceActions;
  portableModules = [
    {
      services = lib.mapAttrs (name: service: {
        lifecycle = {
          type = service.nns.type;
          requires = service.nns.after;
          startTimeout = 0;
        };
        process.argv = if name == "nns-dispatcher" then dispatcherArgv else [ serviceActions.${name}.action ];
      }) allServices;
    }
  ];
  serviceDefinitions =
    if serviceManagerDefinition.render == null then
      null
    else
      serviceManagerDefinition.render {
        inherit pkgs lib;
        services = serviceActions;
        modules = portableModules;
      };
  serviceGraph = lib.toposort (left: right: builtins.elem left allServices.${right}.nns.after) serviceNames;
  serviceIds = if serviceGraph ? result then map (name: "svc-${name}") serviceGraph.result else [ ];
  isBootService =
    name: visited:
    !(builtins.elem name visited)
    && allServices.${name}.nns.startAt == "boot"
    && builtins.all (
      dependency: isBootService dependency (visited ++ [ name ])
    ) allServices.${name}.nns.after;
  bootServiceIds = lib.pipe (serviceGraph.result or [ ]) [
    (lib.filter (name: isBootService name [ ]))
    (lib.map (name: "svc-${name}"))
  ];
  directoryType = types.submodule (
    { config, ... }: {
      options = {
        path = mkOption { type = types.str; };
        owner = mkOption {
          type = types.enum (builtins.attrNames cfg.accounts);
          default = "root";
        };
        group = mkOption {
          type = types.enum (builtins.attrNames cfg.accounts);
          default = config.owner;
        };
        mode = mkOption {
          type = types.strMatching "[0-7]{3,4}";
          default = "0755";
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
        selinuxContextFromAccount = mkOption {
          type = types.nullOr (types.enum (builtins.attrNames cfg.accounts));
          default = null;
          description = "Copy the account home's SELinux label after checking its configured UID and GID.";
        };
      };
    }
  );
  keyFiles = lib.mapAttrs (
    name: account:
    pkgs.writeText "nns-authorized-keys-${name}" (
      lib.concatStringsSep "\n" account.openssh.authorizedKeys.keys + "\n"
    )
  ) cfg.accounts;
  authorizedKeys = pkgs.writeShellScript "nns-authorized-keys" ''
    set -eu
    case "''${1:-}" in
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: account: ''
        ${name})
          ${lib.getExe' pkgs.coreutils "cat"} ${keyFiles.${name}}
          ${lib.concatMapStrings (file: /* bash */ ''
            if [ -f ${lib.escapeShellArg file} ]; then
              ${lib.getExe' pkgs.util-linux "setpriv"} \
                --reuid ${builtins.toString account.uid} \
                --regid ${builtins.toString account.gid} \
                --clear-groups \
                ${lib.getExe' pkgs.coreutils "cat"} ${lib.escapeShellArg file}
            fi
          '') account.openssh.authorizedKeys.runtimeFiles}
          ;;
      '') cfg.accounts
    )}
      *) exit 1 ;;
    esac
  '';
  sshdConfig = pkgs.writeText "nns-sshd-config" /* sshdconfig */ ''
    Port ${builtins.toString cfg.services.openssh.port}
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
      lib.mapAttrsToList (name: account: /* sshdconfig */ ''
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
      lib.mapAttrsToList (
        name: account: "${name}:x:${builtins.toString account.gid}:${name}"
      ) cfg.accounts
    )}
    nix-trusted:x:${builtins.toString nixTrustedGroupGid}:${
      lib.pipe cfg.accounts [
        (lib.filterAttrs (_: account: account.nixTrusted))
        lib.attrNames
        (lib.concatStringsSep ",")
      ]
    }
    EOF
    cat > "$out/nix/nix.conf" <<'EOF'
    ${lib.pipe cfg.nix.settings [
      (lib.mapAttrsToList (
        key: value:
        "${key} = ${
          if builtins.isBool value then
            lib.boolToString value
          else if builtins.isList value then
            lib.concatStringsSep " " value
          else
            builtins.toString value
        }"
      ))
      (lib.concatStringsSep "\n")
    ]}
    EOF
    printf '%s\n' 'nameserver 1.1.1.1' > "$out/resolv.conf"
    ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt "$out/ssl/certs/ca-certificates.crt"
  '';
  generation = pkgs.runCommand "nns-system-generation" { } ''
    mkdir -p "$out/profiles" "$out/services" "$out/authorized_keys"
    ln -s ${infrastructure} "$out/system-profile"
    ln -s ${etc} "$out/etc"
    ln -s ${serviceManagerDefinition.controller} "$out/service-backend.sh"
    ${lib.optionalString (serviceDefinitions != null) ''
      ln -s ${serviceDefinitions} "$out/service-definitions"
    ''}
    printf '%s\n' ${lib.escapeShellArg cfg.system.serviceManager} > "$out/service-backend"
    printf '1\n' > "$out/service-protocol"
    printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep "\n" bootServiceIds)} > "$out/boot-services"
    printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep "\n" serviceIds)} > "$out/all-services"
    ${lib.pipe runTreeServices [
      (lib.mapAttrsToList (
        name: service: ''
          mkdir -p "$out/services/${name}"
          ln -s ${service.action} "$out/services/${name}/run"
          ${lib.optionalString service.oneshot ''
            touch "$out/services/${name}/oneshot"
            ln -s ${service.finish} "$out/services/${name}/finish"
          ''}
          ${lib.optionalString (service.after != [ ]) ''
            printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep "\n" service.after)} > "$out/services/${name}/after"
          ''}
        ''
      ))
      (lib.concatStringsSep "\n")
    ]}
    ${lib.pipe profiles [
      (lib.mapAttrsToList (name: profile: ''ln -s ${profile} "$out/profiles/${name}"''))
      (lib.concatStringsSep "\n")
    ]}
    cat > "$out/service-control" <<'BASH'
    #!${pkgs.runtimeShell}
    set -eu
    generation=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
    export PATH="$generation/system-profile/bin:/system/bin:/system/xbin"
    export NNS_STATE_DIRECTORY=${lib.escapeShellArg state}
    export NNS_ETC_DIRECTORY=${lib.escapeShellArg etcDirectory}
    export NNS_LAUNCHER=${lib.escapeShellArg cfg.system.launcher}
    exec ${pkgs.runtimeShell} ${./service-runtime.sh} "$generation" "$@"
    BASH
    chmod 755 "$out/service-control"
    ${lib.pipe keyFiles [
      (lib.mapAttrsToList (name: file: /* bash */ ''ln -s ${file} "$out/authorized_keys/${name}"''))
      (lib.concatStringsSep "\n")
    ]}
    ${lib.optionalString cfg.services.openssh.enable /* bash */ ''
      touch "$out/sshd-enabled"
      ln -s ${sshdConfig} "$out/sshd_config"
      ln -s ${checkSshd} "$out/check-sshd"
    ''}
    cat > "$out/activate" <<'BASH'
    #!${pkgs.runtimeShell}
    set -eu
    generation=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
    export PATH="$generation/system-profile/bin:/system/bin:/system/xbin"
    export NNS_STATE_DIRECTORY=${lib.escapeShellArg state}
    export NNS_ETC_DIRECTORY=${lib.escapeShellArg etcDirectory}
    export NNS_PROFILE_DIRECTORY=${lib.escapeShellArg profileDirectory}
    export NNS_NIX_CONF_DIRECTORY=${lib.escapeShellArg cfg.system.nixConfDirectory}
    export NNS_LAUNCHER=${lib.escapeShellArg cfg.system.launcher}
    export NNS_SERVICE_RUNTIME=${lib.escapeShellArg "${./service-runtime.sh}"}
    exec ${pkgs.runtimeShell} ${./activate.sh} "$generation" "''${1:-switch}"
    BASH
    chmod 755 "$out/activate"
  '';
in
{
  _class = "nns";
  imports = [
    (lib.mkRemovedOptionModule [ "services" "runit" ] ''
      Use `system.services` for service declarations and `system.serviceManager` to select the backend.
    '')
  ];
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
      serviceManagers = mkOption {
        default = {
          runit = {
            controller = ./service-runit.sh;
            render = null;
            runtimePackages = [ pkgs.runit ];
          };
          s6-rc = {
            controller = ./service-s6-rc.sh;
            render = import ./definitions-s6-rc.nix;
            runtimePackages = [
              pkgs.s6
              pkgs.s6-rc
            ];
          };
          dinit = {
            controller = ./service-dinit.sh;
            render = import ./definitions-dinit.nix;
            runtimePackages = [ pkgs.dinit ];
          };
        };
        type = types.attrsOf (
          types.submodule {
            options = {
              controller = mkOption {
                type = types.path;
                description = ''
                  Shell implementation sourced by the runtime. It defines
                  backend_preflight, backend_prepare, backend_activate,
                  backend_stop, and backend_resume_after_failure.
                '';
              };
              render = mkOption {
                type = types.nullOr (types.functionTo types.package);
                default = null;
                description = ''
                  Builds the manager definitions from the rendered
                  services. Runit needs none and keeps the default.
                '';
              };
              runtimePackages = mkOption {
                type = types.listOf types.package;
                default = [ ];
                description = "Packages added to the system profile for supervision and control tools.";
              };
            };
          }
        );
        description = "Service manager implementations selectable through system.serviceManager.";
      };
      serviceManager = mkOption {
        type = types.enum (builtins.attrNames cfg.system.serviceManagers);
        default = "runit";
        description = "Service manager used to render and control NNS services.";
      };
      services = mkOption {
        default = { };
        type = types.attrsOf serviceType;
        description = "Backend-neutral service definitions managed by the selected NNS service manager.";
      };
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
      directories = mkOption {
        type = types.attrsOf directoryType;
        default = { };
        description = "Root-managed directories, applied by generated directory-<name> oneshot jobs on each activation.";
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
              openssh.authorizedKeys = {
                keys = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Declarative SSH public keys authorized for this account.";
                };
                runtimeFiles = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Runtime authorized-key files read as this account's UID/GID, never as root.";
                };
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
    system.services =
      lib.mapAttrs' (
        name: directory:
        lib.nameValuePair "directory-${name}" {
          nns = {
            type = "oneshot";
            inherit (directory) startAt after;
          };
          process.argv = [
            (import ./directory.nix {
              inherit
                lib
                pkgs
                name
                directory
                ;
              accounts = cfg.accounts;
            })
          ];
        }
      ) cfg.system.directories
      // {
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
      ++ lib.mapAttrsToList (name: directory: {
        assertion =
          validName name
          && lib.hasPrefix "/" directory.path
          && builtins.all (part: part != "" && part != "." && part != "..") (
            lib.drop 1 (lib.splitString "/" directory.path)
          )
          && !(lib.hasInfix "\n" directory.path)
          && !(lib.hasInfix "\r" directory.path);
        message = "Invalid NNS directory path or name: ${name}";
      }) cfg.system.directories
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
          serviceLib.getAssertions [ "system" "services" name ] service
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
                && name != "nns-dispatcher"
                && builtins.all validVariable (builtins.attrNames service.process.environment)
                && builtins.all (
                  dependency: builtins.hasAttr dependency enabledServices && dependency != name
                ) service.nns.after
                && service.configData == { }
                && service.services == { }
                && service.process.reloadCommand == null
                && !service.notificationProtocol.systemd
                && !service.notificationProtocol.s6;
              message = "Invalid or unsupported NNS service: ${name}";
            }
          ]
        ) cfg.system.services
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
          assertion = !cfg.services.openssh.enable || cfg.accounts.root.openssh.authorizedKeys.keys != [ ];
          message = "NNS root SSH requires explicit administrative public keys";
        }
        {
          assertion =
            cfg.accounts.root.openssh.authorizedKeys.runtimeFiles == [ ]
            &&
              builtins.length (lib.unique (map (account: account.uid) (builtins.attrValues cfg.accounts)))
              == builtins.length (builtins.attrNames cfg.accounts);
          message = "NNS accounts must have unique UIDs and root keys must be declarative";
        }
      ];
  };
}