{
  description = "RecipeSage and its service dependencies, run natively (no docker)";

  inputs = {
    # Pinned to the revision this flake was tested against. Needs nodejs_26,
    # pnpm_10 and fetchPnpmDeps fetcherVersion 5 (nixpkgs 26.11+).
    nixpkgs.url = "github:NixOS/nixpkgs/2786a2a72088ecf32aea5b3ec52099e6a7cff78f";

    # The RecipeSage source. Bump the tag together with `pnpmDepsHash` below.
    # To build a local checkout instead:
    #   nix build .#recipesage-server --override-input recipesage-src path:/path/to/recipesage
    recipesage-src = {
      url = "github:julianpoy/recipesage/v4.1.6";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      recipesage-src,
    }:
    let
      version = "4.1.6";
      # Hash of the pnpm store for recipesage-src's pnpm-lock.yaml. When it
      # changes, set it to "" and copy the `got:` hash from the build error.
      pnpmDepsHash = "sha256-rpdLduAA6v3HUCHkgXhn8bzFqGo0TXNHXwF4ca+cjB8=";

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          rs = pkgs.callPackage ./nix/recipesage.nix {
            src = recipesage-src;
            inherit version pnpmDepsHash;
          };
          pushpin = pkgs.callPackage ./nix/pushpin.nix { };
          grocery-categorizer = pkgs.callPackage ./nix/grocery-categorizer.nix { };
        in
        {
          recipesage-server = rs.server;
          recipesage-frontend = rs.frontend;
          recipesage-www = rs.www;
          inherit pushpin grocery-categorizer;

          # Whole stack as local processes: `nix run .#stack`
          stack = pkgs.callPackage ./nix/stack.nix {
            server = rs.server;
            frontend = rs.frontend;
            inherit pushpin;
          };

          default = rs.server;
        }
      );

      apps = forAllSystems (pkgs: {
        default = self.apps.${pkgs.stdenv.hostPlatform.system}.stack;
        stack = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.stack;
        };
      });

      nixosModules = {
        recipesage = import ./nix/module.nix { inherit self; };
        default = self.nixosModules.recipesage;
      };

      # Example host, useful as a starting point and for `nix flake check`.
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.default
          {
            boot.isContainer = true; # no bootloader/filesystems needed to evaluate
            system.stateVersion = "26.05";
            networking.firewall.allowedTCPPorts = [ 80 ];
            services.recipesage = {
              enable = true;
              hostName = "recipes.example.com";
              publicUrl = "http://recipes.example.com";
              # environmentFile = "/run/secrets/recipesage.env"; # GRIP_KEY, AI_API_KEY, ...
            };
          }
        ];
      };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            nodejs_26
            (pnpm_10.override { nodejs-slim = nodejs-slim_26; })
            postgresql_16
            valkey
            self.packages.${pkgs.stdenv.hostPlatform.system}.pushpin
            openssl
            mdbtools
            poppler-utils
            pandoc
            libheif
          ];
          env = {
            PRISMA_SCHEMA_ENGINE_BINARY = "${pkgs.prisma-engines_7}/bin/schema-engine";
            NX_NO_CLOUD = "true";
          };
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
