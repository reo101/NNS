{ pkgs }:
let
  inherit (pkgs) lib;
  cross = pkgs.pkgsCross.musl64;
  crossRejected =
    if cross.stdenv.buildPlatform.config == cross.stdenv.hostPlatform.config then
      true
    else
      !(builtins.tryEval
        (import ../../nix/service-backends/s6-rc.nix {
          pkgs = cross;
          services = { };
        }).drvPath
      ).success;
  crossSourceOnly =
    (builtins.tryEval
      (import ../../nix/service-backends/s6-rc.nix {
        pkgs = cross;
        services = { };
        compileDatabase = false;
      }).drvPath
    ).success;
  evaluate =
    backend: definition:
    import ../../nix/service-backends {
      inherit pkgs backend;
      modules = [ definition ];
    };
  rejects =
    backend: definition:
    !(builtins.tryEval (builtins.deepSeq (evaluate backend definition).manifest true)).success;
  command = [ "${pkgs.coreutils}/bin/true" ];
  service = {
    process.argv = command;
  };
  invalid = [
    { services.empty = { }; }
    { services.example.process.argv = [ "" ]; }
    { services.example.process.argv = [ "relative-command" ]; }
    { services."invalid.name" = service; }
    {
      services.example = service // {
        lifecycle.requires = [ "absent" ];
      };
    }
    {
      services.first = service // {
        lifecycle.requires = [ "second" ];
      };
      services.second = service // {
        lifecycle.requires = [ "first" ];
      };
    }
    {
      services.self = service // {
        lifecycle.requires = [ "self" ];
      };
    }
    {
      services.example = service // {
        process = {
          argv = command;
          environment."INVALID-NAME" = "value";
        };
      };
    }
    {
      services.example = service // {
        process = {
          argv = command;
          reloadCommand = "echo reload";
        };
      };
    }
    {
      services.example = service // {
        process = {
          argv = command;
          reloadSignal = "HUP";
        };
      };
    }
    {
      services.example = service // {
        notificationProtocol.systemd = true;
      };
    }
    {
      services.example = service // {
        notificationProtocol.s6 = true;
        lifecycle.type = "oneshot";
      };
    }
    {
      services.example = service // {
        lifecycle.notificationFd = 2;
      };
    }
    {
      services.example = service // {
        lifecycle.startTimeout = -1;
      };
    }
    {
      services.parent.services.child = service // {
        lifecycle.notificationFd = 2;
      };
    }
    {
      services.example.process = {
        argv = command;
        environment.INVALID_TYPE = 10;
      };
    }
    {
      services.example = service // {
        configData.file.text = "data";
      };
    }
    {
      services.example = service // {
        assertions = [
          {
            assertion = false;
            message = "intentional service assertion";
          }
        ];
      };
    }
    {
      services.parent.services.child = service // {
        assertions = [
          {
            assertion = false;
            message = "nested service assertion";
          }
        ];
      };
    }
    {
      services.parent = {
        services.child = service;
        lifecycle.requires = [ "parent/child" ];
      };
    }
    {
      services.parent = {
        services.child = service;
        process.environment.IGNORED = "no";
      };
    }
    {
      services.parent.services.child = service;
      services.example = service // {
        lifecycle.requires = [ "parent" ];
      };
    }
  ];
  withConfiguration =
    backend: directory: files:
    import ../../nix/service-backends {
      inherit pkgs backend;
      configurationDirectory = directory;
      modules = [
        {
          services.example = service // {
            configData = files;
          };
        }
      ];
    };
  configurationRejects =
    backend: directory: files:
    !(builtins.tryEval (builtins.deepSeq (withConfiguration backend directory files).manifest true))
    .success;
  checkBackend =
    backend:
    let
      nested = evaluate backend {
        services.parent.services.child = service;
        services.parent-child = service;
        services.consumer = service // {
          lifecycle.requires = [ "parent/child" ];
        };
      };
      conditional = evaluate backend { services.disabled = lib.mkIf false service; };
      moduleArguments = evaluate backend {
        services.parent.services.child = { pkgs, ... }: {
          process.argv = [ "${pkgs.coreutils}/bin/true" ];
          process.environment.SERVICE_TOOL = pkgs.coreutils;
        };
      };
      disabled = evaluate backend {
        services.example = service // {
          configData.unused = {
            enable = false;
            text = "unused";
          };
        };
      };
      notification = evaluate backend {
        services.example = service // {
          notificationProtocol = {
            s6 = true;
            systemd = true;
          };
        };
      };
      configuration = withConfiguration backend "/tmp/portable-service-configuration" {
        nested = {
          name = "nested/config.txt";
          text = "content";
        };
      };
    in
    assert lib.assertMsg (builtins.all (rejects backend) invalid) (
      "accepted invalid definitions for ${backend}: "
      + lib.concatStringsSep ", " (
        lib.imap0 (
          index: definition: if rejects backend definition then "" else builtins.toString index
        ) invalid
      )
    );
    assert configurationRejects backend "relative" { };
    assert configurationRejects backend "/tmp/../escaped" { };
    assert configurationRejects backend "/tmp/valid" {
      invalid = {
        name = "../escaped";
        text = "content";
      };
    };
    assert configurationRejects backend "/tmp/valid" {
      first = {
        name = "same";
        text = "one";
      };
      second = {
        name = "same";
        text = "two";
      };
    };
    assert
      nested.manifest.services."parent/child".nativeName
      != nested.manifest.services.parent-child.nativeName;
    assert nested.manifest.services."parent/child".requires == [ ];
    assert nested.manifest.services.consumer.requires == [ "parent/child" ];
    assert nested.manifest.containers == [ "parent" ];
    assert conditional.manifest.services == { };
    assert
      moduleArguments.config.services.parent.services.child.process.environment.SERVICE_TOOL
      == "${pkgs.coreutils}";
    assert disabled.manifest.services.example.type == "longrun";
    assert notification.manifest.services.example.notificationFd == 3;
    assert
      configuration.config.services.example.configData.nested.path
      == "/tmp/portable-service-configuration/svc-example/nested/config.txt";
    true;
in
assert crossRejected;
assert crossSourceOnly;
assert rejects "nosh" { services.example = service; };
assert rejects "unknown" { services.example = service; };
assert builtins.all checkBackend [
  "s6-rc"
  "dinit"
];
true
