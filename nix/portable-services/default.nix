{
  pkgs,
  manager,
  modules ? [ ],
  configurationDirectory ? null,
  compileS6Database ? true,
}:
let
  inherit (pkgs) lib;
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
        (import ./service-options.nix {
          inherit pkgs configurationDirectory hasEnvironment;
        })
      ];
      extraRootSpecialArgs = { inherit pkgs; };
    }).serviceSubmodule;
  evaluation = lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      {
        options.services = lib.mkOption {
          type = lib.types.attrsOf serviceType;
          default = { };
          description = "Nixpkgs portable services rendered for a subordinate service manager.";
        };
      }
    ]
    ++ modules;
  };
  flatten =
    parent: services:
    lib.concatLists (
      lib.mapAttrsToList (
        name: service:
        let
          path = parent ++ [ name ];
        in
        [
          {
            inherit path service;
            logicalName = lib.concatStringsSep "/" path;
          }
        ]
        ++ flatten path service.services
      ) services
    );
  nodes = flatten [ ] evaluation.config.services;
  checkedNodes = map (node: {
    inherit (node.service) lifecycle notificationProtocol;
    inherit (node.service.process) environment reloadCommand reloadSignal;
    argv = map builtins.toString node.service.process.argv;
    files = lib.mapAttrs (_: file: {
      inherit (file) name;
      source = "${file.source}";
    }) (enabledFiles node.service);
  }) nodes;
  active = builtins.filter (node: node.service.process.argv != [ ]) nodes;
  containers = builtins.filter (node: node.service.process.argv == [ ]) nodes;
  byName = lib.listToAttrs (map (node: lib.nameValuePair node.logicalName node) active);
  nativeName = path: "svc-${lib.concatStringsSep "." path}";
  validSegment = name: builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" name != null;
  validRelativePath =
    path:
    path != ""
    && !(lib.hasPrefix "/" path)
    && !(lib.hasInfix "\n" path)
    && !(lib.hasInfix "\r" path)
    && builtins.all (part: part != "" && part != "." && part != "..") (lib.splitString "/" path);
  enabledFiles = service: lib.filterAttrs (_: file: file.enable) service.configData;
  configurationFiles = lib.concatMap (
    node:
    lib.mapAttrsToList (_: file: {
      source = "${file.source}";
      name = "${nativeName node.path}/${file.name}";
    }) (enabledFiles node.service)
  ) active;
  graphValid = builtins.all (
    node: builtins.all (name: builtins.hasAttr name byName) node.service.lifecycle.requires
  ) active;
  graph =
    if graphValid then
      lib.toposort (left: right: builtins.elem left byName.${right}.service.lifecycle.requires) (
        builtins.attrNames byName
      )
    else
      { };
  failures =
    lib.optional
      (
        !(builtins.elem manager [
          "s6-rc"
          "dinit"
        ])
      )
      (
        if manager == "nosh" then
          "nosh is deferred; see nix/portable-services/nosh-research.md"
        else
          "unsupported manager: ${manager}"
      )
    ++ lib.optional (
      configurationDirectory != null
      && (
        !(lib.hasPrefix "/" configurationDirectory)
        || !(validRelativePath (lib.removePrefix "/" configurationDirectory))
      )
    ) "configurationDirectory must be an absolute path without empty, dot, or parent components"
    ++ lib.concatMap (
      node:
      lib.optional (
        !(builtins.all validSegment node.path)
      ) "invalid service ownership path: ${node.logicalName}"
    ) nodes
    ++ lib.concatMap (
      node:
      let
        service = node.service;
        prefix = "${node.logicalName}: ";
        files = enabledFiles service;
      in
      lib.optional (!(lib.hasPrefix "/" (builtins.head service.process.argv))) (
        prefix + "the executable must be an absolute path"
      )
      ++ lib.optional (service.process.reloadCommand != null || service.process.reloadSignal != null) (
        prefix + "reload commands and signals are not implemented"
      )
      ++ lib.optional (service.notificationProtocol.systemd && !service.notificationProtocol.s6) (
        prefix + "systemd-only readiness is not supported; declare s6 notification support"
      )
      ++ lib.optional (service.lifecycle.type == "oneshot" && service.notificationProtocol.s6) (
        prefix + "oneshots use exit status, not readiness notifications"
      )
      ++ lib.optional (
        !(builtins.all (name: builtins.match "[A-Za-z_][A-Za-z0-9_]*" name != null) (
          builtins.attrNames service.process.environment
        ))
      ) (prefix + "invalid environment variable name")
      ++ lib.optional (files != { } && configurationDirectory == null) (
        prefix + "configData requires configurationDirectory"
      )
      ++ lib.optional (!(builtins.all (file: validRelativePath file.name) (builtins.attrValues files))) (
        prefix + "invalid configData file name"
      )
      ++ lib.optional (
        builtins.length (lib.unique (map (file: file.name) (builtins.attrValues files)))
        != builtins.length (builtins.attrNames files)
      ) (prefix + "duplicate configData destination")
      ++ lib.concatMap (
        dependency:
        lib.optional (!(builtins.hasAttr dependency byName)) (
          prefix + "unknown process dependency: ${dependency}"
        )
        ++ lib.optional (dependency == node.logicalName) (prefix + "a service cannot require itself")
      ) service.lifecycle.requires
    ) active
    ++ lib.concatMap (
      node:
      let
        service = node.service;
      in
      lib.optional (
        service.services == { }
        || service.lifecycle.type != "longrun"
        || service.lifecycle.requires != [ ]
        || service.process.environment != { }
        || enabledFiles service != { }
        || service.notificationProtocol.s6
        || service.notificationProtocol.systemd
        || service.process.reloadCommand != null
        || service.process.reloadSignal != null
      ) "${node.logicalName}: a processless owner must have children and cannot declare runtime behavior"
    ) containers
    ++ lib.optional (graphValid && !(graph ? result)) "service startup dependencies contain a cycle"
    ++ lib.concatMap (
      name:
      map (assertion: assertion.message) (
        builtins.filter (assertion: !assertion.assertion) (
          serviceLib.getAssertions [ "services" name ] evaluation.config.services.${name}
        )
      )
    ) (builtins.attrNames evaluation.config.services);
  warnings = lib.concatMap (
    name: serviceLib.getWarnings [ "services" name ] evaluation.config.services.${name}
  ) (builtins.attrNames evaluation.config.services);
  normalized = lib.listToAttrs (
    map (
      node:
      let
        service = node.service;
        identifier = nativeName node.path;
      in
      lib.nameValuePair identifier {
        inherit (service.lifecycle) type startTimeout;
        command = pkgs.writeShellScript "portable-service-${identifier}" ''
          set -eu
          exec ${lib.getExe' pkgs.coreutils "env"} ${
            lib.escapeShellArgs (
              lib.concatLists (
                lib.mapAttrsToList (
                  name: value:
                  if value == null then
                    [
                      "-u"
                      name
                    ]
                  else
                    [ ]
                ) service.process.environment
              )
              ++ [ "--" ]
              ++ lib.mapAttrsToList (name: value: "${name}=${value}") (
                lib.filterAttrs (_: value: value != null) service.process.environment
              )
              ++ [ (lib.getExe' pkgs.execline "exec") ]
              ++ service.process.argv
            )
          }
        '';
        notificationFd = if service.notificationProtocol.s6 then service.lifecycle.notificationFd else null;
        dependencies = map (name: nativeName byName.${name}.path) (lib.unique service.lifecycle.requires);
      }
    ) active
  );
  native = import (if manager == "s6-rc" then ./s6-rc.nix else ./dinit.nix) {
    inherit pkgs;
    services = normalized;
    compileDatabase = compileS6Database;
  };
  manifest = {
    schemaVersion = 1;
    inherit manager configurationDirectory;
    containers = map (node: node.logicalName) containers;
    services = lib.listToAttrs (
      map (
        node:
        lib.nameValuePair node.logicalName {
          nativeName = nativeName node.path;
          inherit (node.service.lifecycle) type requires startTimeout;
          notificationFd = normalized.${nativeName node.path}.notificationFd;
        }
      ) active
    );
  };
  manifestFile = pkgs.writeText "portable-services-manifest.json" (builtins.toJSON manifest);
  package = pkgs.runCommand "portable-services-${manager}" { } ''
    mkdir -p "$out"
    cp -r ${native}/. "$out/"
    cp ${manifestFile} "$out/manifest.json"
    mkdir -p "$out/configuration"
    ${lib.concatMapStringsSep "\n" (
      file:
      ''install -D -m 644 ${lib.escapeShellArg file.source} "$out"/configuration/${lib.escapeShellArg file.name}''
    ) configurationFiles}
  '';
in
builtins.deepSeq checkedNodes (
  if failures != [ ] then
    throw ("portable services:\n" + lib.concatMapStringsSep "\n" (message: "- ${message}") failures)
  else
    lib.foldr lib.warn {
      inherit package manifest warnings;
      runtimePackages =
        if manager == "s6-rc" then
          [
            pkgs.s6
            pkgs.s6-rc
          ]
        else
          [ pkgs.dinit ];
      inherit (evaluation) config options;
    } warnings
)
