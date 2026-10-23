# Nosh backend feasibility

Nosh is not an implemented backend. Selecting it fails during evaluation. No nosh runtime test or Android compatibility test was performed.

## Package availability

The repository's pinned Nixpkgs has no `pkgs.nosh` attribute. Upstream distributes a standalone source package with multiple tools, not a ready Nix derivation.

The source page lists nosh 1.41 archives and a slashpackage-style build layout. Before adding a renderer, package a pinned source archive through Nix, establish the build dependencies and installation layout, and test the required binaries. The source page does not supply a source digest. Nix can calculate and pin one, but this research did not build the source package.

This is a packaging task, not evidence that nosh cannot run in the required scope.

## Native service model

A native bundle contains `service/` and `supervise/`. Executable `service/run` starts the process. Optional `start`, `restart`, and `stop` programs control other transitions. The service manager runs these programs in the bundle's service directory. Generated wrappers can set environment values and execute the portable argv without shell expansion.

Bundle links express startup requests and ordering. Nosh distinguishes those relations. An `after/` link alone is not equivalent to this library's `lifecycle.requires`, which requires successful prerequisite startup.

The `remain` marker permits a service to remain considered running after its process exits. `ready_after_run` supplies a related readiness convention for completed runs. These are promising ingredients for finite services, but a renderer must test successful and unsuccessful exits separately. A marker cannot be assumed to implement the required finite success contract by itself.

## Readiness gap

Nixpkgs declares process capabilities through `notificationProtocol.s6` and `notificationProtocol.systemd`. The implemented backends use the s6 protocol: a newline on a configured descriptor.

The reviewed nosh documentation does not establish native handling of that descriptor protocol. Its `ready_after_run` convention is not the same mechanism. Do not map notification-enabled longruns to process existence or silently ignore their capability declaration.

A first nosh backend must either reject that capability or provide and test a readiness adapter. The shared runtime fixture explicitly tests descriptor-5 notification, so an untested renderer cannot claim parity.

## Process scope and API

Nosh separates its service manager from its PID 1 system manager. The service manager can run below another system manager. This matches the subordinate scope required here and does not imply replacing Android init.

`system-control` is the higher-level interface for bundle jobs. `service-control` operates on individual supervisor control interfaces. These are separate responsibilities, like the distinction between a graph transition engine and a process supervisor.

## Next steps

1. Build nosh reproducibly through Nix.
2. Run a subordinate manager and one native bundle without host system integration.
3. Test finite exit codes and startup-success dependencies.
4. Establish a readiness mapping or an explicit capability rejection.
5. Add the renderer only after those tests pass.

Sources:

- [Service-bundle format](https://jdebp.uk/Softwares/nosh/guide/commands/service-bundle.xml)
- [Service-manager interface](https://jdebp.uk/Softwares/nosh/guide/commands/service-manager.xml)
- [System-control interface](https://jdebp.uk/Softwares/nosh/guide/commands/system-control.xml)
- [Source package](https://jdebp.uk/Softwares/nosh/source-package.html)
- [Toolset architecture](https://jdebp.uk/Softwares/nosh/)
- [s6 readiness protocol](https://skarnet.org/software/s6/notifywhenup.html)
