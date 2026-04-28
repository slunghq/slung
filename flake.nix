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
            # Use Zig 0.16.0 from the overlay
            zigpkgs."0.16.0"

            # Additional libraries
            pkg-config

            # File watching for hot reload
            entr
            watchexec
          ];

          shellHook = ''
                        echo "Zig version: $(zig version)"
                        echo "Development environment!"
                        echo ""
                        echo "Commands:"
                        echo "  zig build run         - Build and run once"
                        echo "  zig-watch             - Watch files and auto-rebuild/run"
                        echo "  zig-watch-test        - Watch files and auto-rebuild/test"
                        echo ""

                        # Create helper scripts for file watching
                        cat > zig-watch << 'EOF'
            #!/usr/bin/env bash
            echo "Watching Zig files for changes... (Press Ctrl+C to stop)"
            zig build run --watch
            EOF
                        chmod +x zig-watch
                        alias zig-watch=./zig-watch

                        cat > zig-watch-test << 'EOF'
            #!/usr/bin/env bash
            echo "Watching Zig files for changes (test)... (Press Ctrl+C to stop)"
            zig build test --summary all --watch
            EOF
                        chmod +x zig-watch-test
                        alias zig-watch-test=./zig-watch-test
          '';
        };
      }
    );
}
