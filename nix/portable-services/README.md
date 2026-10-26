# Portable service managers

This library renders Nixpkgs modular services for s6 with s6-rc, or Dinit. It does not depend on NNS, NixOS, Android, or a PID 1 replacement. It does not select the NNS runtime. The [NNS integration](../nns-system/README.md) selects and activates a manager separately.

The implementation uses the portable service schema from the supplied `pkgs`. It adds a small `lifecycle` extension for finite jobs, startup prerequisites, readiness descriptors, and startup timeouts. The managers own runtime state. Generated command wrappers contain no dependency waits or completion markers.

## Evaluate a collection

```nix
let
  result = import ./nix/portable-services {
    inherit pkgs;
    manager = "s6-rc"; # Or "dinit".
    modules = [
      {
        services.prepare = {
          lifecycle.type = "oneshot";
          process.argv = [ "${pkgs.coreutils}/bin/true" ];
        };
        services.worker = {
          lifecycle.requires = [ "prepare" ];
          process.argv = [ "${pkgs.coreutils}/bin/sleep" "infinity" ];
        };
      }
    ];
  };
in
result.package
```

A flake consumer can call `inputs.nns.lib.evalPortableServices` with the same arguments. The function accepts its caller's package set and has no NNS runtime dependency.

The arguments are:

| Argument | Meaning |
|---|---|
| `pkgs` | The package set that supplies the portable schema and manager packages. |
| `manager` | `"s6-rc"` or `"dinit"`. |
| `modules` | Module definitions for a top-level `services` collection. |
| `configurationDirectory` | Optional absolute directory for published `configData`. Required when enabled configuration files exist. |
| `compileS6Database` | Default `true`. If `false`, emit s6-rc sources without compiling a database. |

The result exposes `package`, `runtimePackages`, `manifest`, `config`, `options`, and `warnings`. Add `runtimePackages` to the containing system's tools. The package contains native definitions and is not itself an executable service manager.

| Manager | Package contents |
|---|---|
| s6-rc | `source/`, `compiled/` unless source-only, `configuration/`, and `manifest.json`. |
| Dinit | `services/` descriptions, `configuration/`, and `manifest.json`. |

Both provide a native aggregate named `default`. The containing system selects which services or aggregate to start. It also owns manager startup, writable runtime state, and shutdown.

## Service semantics

| Declaration | Shared contract |
|---|---|
| `process.argv` | Raw arguments, with no shell expansion. The executable must be an absolute path. |
| `process.flags` and `flagFormat` | Nixpkgs renders flags into argv, including ordering and repeated flags. |
| `process.environment` | Explicit assignments. An empty string stays empty. `null` removes an inherited variable. Other variables remain inherited. |
| `lifecycle.type` | `"longrun"` by default, or `"oneshot"` for a finite startup action. |
| `lifecycle.requires` | Root-relative service ownership paths that must start successfully before this service starts. |
| `notificationProtocol.s6` | The process signals readiness by writing a newline to the configured descriptor. |
| `lifecycle.notificationFd` | The readiness descriptor, default 3. The service author must configure the process to use it. |
| `lifecycle.startTimeout` | Startup observation timeout in seconds, default 30. Zero permits an unlimited wait. |

Longruns restart after process exit, including successful exit. Dinit's default retry-count limit is disabled for this contract. Restart delays remain manager-specific. Successful oneshots remain started without a resident process for that job. Failed oneshots require an explicit retry. This library does not add automatic finite-job retries.

A startup prerequisite is not an ongoing lifetime dependency. s6-rc uses dependency transitions. Dinit uses `depends-ms`, not lifetime-coupled `depends-on`. Reverse stop behavior, aggregate failure scheduling, manager restart recovery, and interruption handling remain native. In particular, s6-rc can continue independent transitions after failure. Do not assume that Dinit's aggregate failure scheduling is identical.

A timeout is not a rollback guarantee. Dinit scripted startup is interruptible and has a three-second stop timeout. Cancellation of a finite action differs between managers. Finite actions must tolerate retry after interruption. Without readiness notification, process startup does not establish application health.

The wrappers use GNU env and execline's exec program. This preserves raw arguments and valid environment names that Bash treats as read-only. The exec program also prevents an executable name containing `=` from becoming an env assignment. Both utilities replace themselves with the service process. They are not resident workers.

## Ownership and names

Nested `services` represent ownership only. A parent does not automatically start before its children. A processless parent can group child declarations, but cannot declare its own runtime behavior.

Each ownership segment must match `[A-Za-z0-9][A-Za-z0-9_-]*`. Dependencies use paths such as `"database"` or `"application/worker"`. A dependency must name a process, not a processless container.

Native names use a `svc-` prefix and dot-separated ownership segments. Thus `application/worker` becomes `svc-application.worker`, while `application-worker` becomes `svc-application-worker`. These names cannot collide. `manifest.json` records the mapping.

## Configuration data

The library supplies each `configData.<name>.path`. For example:

```nix
{
  configurationDirectory = "/run/service-configuration";
  modules = [
    {
      services.worker = { config, ... }: {
        configData.settings.text = "example configuration\n";
        process.argv = [
          "/absolute/path/to/worker"
          "--configuration"
          config.configData.settings.path
        ];
      };
    }
  ];
}
```

The resulting path is `/run/service-configuration/svc-worker/settings`. The package stages the file under `configuration/svc-worker/settings`. A file can also use `source = ./settings.conf` instead of `text`.

The containing system must publish the staged tree into `configurationDirectory` before starting the affected services. The renderer never writes that directory. The containing system also owns file permissions, ownership, atomic replacement, and any reload action. Disabled entries are not staged. Configuration in the Nix store is not secret storage.

## Unsupported features

The library rejects reload commands and reload signals, systemd-only readiness, readiness notifications on oneshots, invalid names, invalid environment keys, missing process prerequisites, and dependency cycles. It preserves service-level assertions and warnings, including nested declarations. If a process advertises both notification protocols, these managers select its s6 protocol.

There is no generic control daemon, activation engine, Android unlock watcher, credential manager, logging policy, or automatic database-update transaction. These are integration responsibilities, not hidden emulations in run scripts.

By default, the s6-rc renderer requires a native package set. Cross-compiling its database with a compiler that embeds another platform's helper paths is rejected. Native package sets can use remote builders of their own architecture.

If `compileS6Database = false`, the package contains sources and no compiled database. This mode accepts cross package sets. The containing system must compile the sources with its target compiler before activation. NNS uses this mode during preflight. The runtime tests cover Linux only.

Nosh is deferred, not represented by an untested third renderer. [nosh-research.md](nosh-research.md) records the package and readiness gaps.

## Tests

From the repository root, run:

```sh
nix run --impure --file tests/portable-services/default.nix tests -L
```

The runner uses the repository's pinned Nixpkgs. Evaluation tests cover invalid declarations and nested schema composition. Generated definitions pass `s6-rc-compile` or `dinit-check` during the build.

The runtime suite passes 18 cases across both actual managers. Empty collections also build for both managers. The shared contract covers finite success and failure, explicit retry, independent service startup, repeated start, raw arguments and flags, environment removal, literal environment values, configuration text and file sources, ownership paths, descriptor-5 readiness, readiness timeout, repeated process exits, and explicit stop/start.

The runtime suite uses private user, mount, and PID namespaces. It mounts a private `/tmp` for configuration publication and contains all descendants. It requires Linux user namespaces, not host root. No device access or NNS deployment is part of these tests.
