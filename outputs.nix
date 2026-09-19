inputs:
inputs.flake-parts.lib.mkFlake { inherit inputs; } (
  {
    withSystem,
    flake-parts-lib,
    lib,
    config,
    ...
  }:
  {
    systems = import inputs.systems.outPath;

    imports = [
      inputs.flake-file.flakeModules.default
    ];

    flake-file = {
      nixConfig = {
        commit-lockfile-summary = "chore(flake): update `flake.lock`";
        extra-experimental-features = [
          "pipe-operators"
        ];
      };

      inputs = {
        systems = {
          url = "github:nix-systems/default";
        };

        nixpkgs = {
          url = "github:nixos/nixpkgs/nixos-unstable";
        };

        flake-file = {
          url = "github:vic/flake-file";
        };

        flake-parts = {
          url = "github:hercules-ci/flake-parts";
          inputs.nixpkgs-lib.follows = "nixpkgs";
        };

        zig-flake = {
          url = "github:silversquirl/zig-flake";
          inputs.nixpkgs.follows = "nixpkgs";
        };

        zls = {
          url = "github:zigtools/zls/0.16.0";
          inputs.nixpkgs.follows = "nixpkgs";
          inputs.zig-flake.follows = "zig-flake";
        };
      };
    };

    debug = true;

    perSystem =
      {
        pkgs,
        system,
        inputs',
        self',
        ...
      }:
      {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.android-tools
            inputs'.zig-flake.packages.zig_0_16_0
          ];
        };
      };
  }
)
