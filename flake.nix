# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025 Jonathan D.A. Jewell
#
# flake.nix - Nix Flake for hybrid-automation-router
# Fallback package manager per RSR guidelines (Guix primary)
#
# Usage:
#   nix develop          # Enter development shell
#   nix build            # Build the package
#   nix flake check      # Run checks

{
  description = "HAR (Hybrid Automation Router) - BGP for Infrastructure Automation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Elixir/Erlang versions matching mix.exs requirements
        erlang = pkgs.erlang_26;
        elixir = pkgs.elixir_1_15;

        # Build inputs for Mix project
        buildInputs = with pkgs; [
          erlang
          elixir
          openssl
          git
        ];

        # Development tools
        devTools = with pkgs; [
          # Elixir tooling
          elixir-ls
          mix2nix

          # Development utilities
          just
          watchexec

          # Security tools
          trivy
          grype
        ];

      in {
        # Development shell
        devShells.default = pkgs.mkShell {
          buildInputs = buildInputs ++ devTools;

          shellHook = ''
            echo "HAR Development Environment"
            echo "============================"
            echo "Erlang: ${erlang.version}"
            echo "Elixir: ${elixir.version}"
            echo ""
            echo "Commands:"
            echo "  mix deps.get    - Install dependencies"
            echo "  mix test        - Run tests"
            echo "  mix dialyzer    - Run type analysis"
            echo "  just --list     - Show available tasks"
            echo ""

            # Set Mix environment
            export MIX_HOME="$PWD/.nix-mix"
            export HEX_HOME="$PWD/.nix-hex"
            export ERL_AFLAGS="-kernel shell_history enabled"

            # Create directories if needed
            mkdir -p "$MIX_HOME" "$HEX_HOME"

            # Install hex and rebar locally
            mix local.hex --force --if-missing
            mix local.rebar --force --if-missing
          '';
        };

        # Package definition
        packages.default = pkgs.beamPackages.mixRelease {
          pname = "har";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = buildInputs;

          mixFodDeps = pkgs.beamPackages.fetchMixDeps {
            pname = "har-deps";
            inherit (self.packages.${system}.default) src version;
            # SHA256 hash will need to be updated after first build
            sha256 = pkgs.lib.fakeSha256;
          };

          meta = with pkgs.lib; {
            description = "Infrastructure automation router - BGP for IaC";
            homepage = "https://github.com/hyperpolymath/hybrid-automation-router";
            license = licenses.agpl3Plus;
            maintainers = [];
            platforms = platforms.unix;
          };
        };

        # Checks
        checks = {
          # Format check
          format = pkgs.runCommand "check-format" {
            buildInputs = [ elixir ];
          } ''
            cd ${self}
            mix format --check-formatted || exit 1
            touch $out
          '';
        };
      }
    );
}
