{
  description = "Slung";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      zig-overlay,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Use Zig 0.15.2 from the overlay
            zigpkgs."0.15.2"

            # Additional libraries
            pkg-config

            # File watching for hot reload
            entr
            watchexec
          ];

          shellHook = ''
                        echo "Zig version: $(zig version)"
                        echo "Development environment ready for raylib!"
                        echo ""
                        echo "Commands:"
                        echo "  zig build run          - Build and run once"
                        echo "  zig-watch             - Watch files and auto-rebuild/run"
                        echo "  zig-watch-build       - Watch files and auto-rebuild only"
                        echo ""

                        # Create helper scripts for file watching
                        cat > zig-watch << 'EOF'
            #!/usr/bin/env bash
            echo "Watching Zig files for changes... (Press Ctrl+C to stop)"
            find src -name "*.zig" | entr -c -r zig build run
            EOF
                        chmod +x zig-watch

                        cat > zig-watch-build << 'EOF'
            #!/usr/bin/env bash
            echo "Watching Zig files for changes (build only)... (Press Ctrl+C to stop)"
            find src -name "*.zig" | entr -c zig build
            EOF
                        chmod +x zig-watch-build
          '';
        };
      }
    );
}
