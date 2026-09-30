{
  description = "inline-values.hx -- debugger values drawn inline in the Helix editor";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    # Provides `helixPlugins`, carrying the cog builder (`buildHelixPlugin`).
    # This plugin has no cog dependencies -- unlike connect.hx, it only talks
    # to the editor.
    helix-plugins.url = "github:maxschipper/helix-plugins-nix";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [inputs.treefmt-nix.flakeModule];
      systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];

      flake.overlays.default = final: prev: {
        helixPlugins =
          (prev.helixPlugins or {})
          // {
            inline-values-hx = final.callPackage ./package.nix {};
          };
      };

      perSystem = {
        pkgs,
        system,
        ...
      }: let
        # The builder lives in the helixPlugins scope, so callPackage from
        # that scope resolves it by name.
        helixPlugins =
          (pkgs.appendOverlays [inputs.helix-plugins.overlays.default]).helixPlugins;
      in {
        packages.default = helixPlugins.callPackage ./package.nix {};
        packages.inline-values-hx = helixPlugins.callPackage ./package.nix {};

        treefmt = {
          projectRootFile = "flake.nix";
          programs.alejandra.enable = true;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Steel itself, plus the LSP that backs the `scheme` language entry.
            # steel-language-server resolves its index out of $STEEL_HOME, which
            # the shellHook points at the dev cog tree below.
            steel
            steel-language-server
          ];

          # A throwaway STEEL_HOME holding this checkout, so `steel` at the
          # prompt resolves `(require "inline-values.hx/...")` exactly the way
          # helix will. Rebuilt per shell; nothing persists.
          shellHook = ''
            export STEEL_HOME="''${STEEL_HOME:-$PWD/.dev/steel-home}"
            mkdir -p "$STEEL_HOME/cogs"
            ln -sfn "$PWD" "$STEEL_HOME/cogs/inline-values.hx"
            echo "inline-values.hx dev shell -- STEEL_HOME=$STEEL_HOME"
          '';
        };
      };
    };
}
