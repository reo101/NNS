{
  pkgs,
  configurationDirectory,
  hasEnvironment,
  parentPath ? [ ],
}:
{ lib, name, ... }:
let
  inherit (lib) mkOption types;
  servicePath = parentPath ++ [ name ];
  nativeName = "svc-${lib.concatStringsSep "." servicePath}";
in
{
  # The portable base supplies child service modules. Merge this extension into
  # their type as well; ownership alone must not imply runtime dependencies.
  options.services = mkOption {
    type = types.attrsOf (
      types.submoduleWith {
        modules = [
          (import ./service-options.nix {
            inherit pkgs configurationDirectory hasEnvironment;
            parentPath = servicePath;
          })
        ];
        specialArgs = { inherit pkgs; };
      }
    );
  };
  options.process = lib.optionalAttrs (!hasEnvironment) {
    environment = mkOption {
      type = types.attrsOf (
        types.nullOr (types.coercedTo (types.either types.path types.package) (value: "${value}") types.str)
      );
      default = { };
      description = "Environment assignments; null removes an inherited variable.";
    };
  };
  options.lifecycle = {
    type = mkOption {
      type = types.enum [
        "longrun"
        "oneshot"
      ];
      default = "longrun";
      description = "A supervised process or a finite startup action.";
    };
    requires = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Successful startup prerequisites, addressed by root-relative ownership paths. No ongoing lifetime coupling is implied.";
    };
    notificationFd = mkOption {
      type = types.ints.between 3 1023;
      default = 3;
      description = "Readiness descriptor when notificationProtocol.s6 is enabled. The service must use this descriptor itself.";
    };
    startTimeout = mkOption {
      type = types.ints.unsigned;
      default = 30;
      description = "Startup observation timeout in seconds; zero permits an unlimited wait. Cancellation of finite actions remains manager-specific.";
    };
  };
  options.configData = mkOption {
    type = types.lazyAttrsOf (
      types.submodule (
        { config, ... }: {
          config.path =
            if configurationDirectory == null then
              throw "portable services: set configurationDirectory before using configData.path"
            else
              "${configurationDirectory}/${nativeName}/${config.name}";
        }
      )
    );
  };
  # An owner can group child declarations without owning a process.
  config.process.argv = lib.mkDefault [ ];
}
