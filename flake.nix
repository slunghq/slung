{
  description = "slung";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";

    zls-0-16.url = "github:zigtools/zls/0.16.0";
    zls-0-16.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay
            , zls-0-16 }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };

        zig = {
          "0.16.0" = pkgs.zigpkgs."0.16.0";
          master   = pkgs.zigpkgs.master;
        };

        zls = {
          "0.16.0" = zls-0-16.packages.${system}.zls;
        };

        mkZigShell = v: pkgs.mkShell {
          buildInputs = [ zig.${v} ];

          shellHook = ''
            echo "slung development environment loaded:"
            echo ""
            echo "  zig version: $(zig version)"
            echo "  zls version: $(zls version)"
            echo ""
          '';
        };

        mkLspShell = v: pkgs.mkShell {
          buildInputs = [ zig.${v} zls.${v} ];

          shellHook = ''
            echo "slung development environment loaded:"
            echo ""
            echo "  zig version: $(zig version)"
            echo "  zls version: $(zls version)"
            echo ""
          '';
        };

      in {
        devShells = {
          default  = mkZigShell "0.16.0";
          "0.16.0" = mkZigShell "0.16.0";
          master   = mkZigShell "master"; # no matching zls for master

          lsp         = mkLspShell "0.16.0";
        };
      }
    );
}
