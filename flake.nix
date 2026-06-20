{
  description = "lish, an embeddable scripting language: reproducible dev environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Pins an exact Zig version regardless of what nixpkgs ships, so the whole
    # workspace (lish, lish-lsp, folio, tree-sitter-lish) builds against the same
    # toolchain: the version-matching guarantee.
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        zig = zig-overlay.packages.${system}."0.16.0";
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            zig # exact 0.16.0
            pkgs.nodejs # tree-sitter grammar tooling
            pkgs.pnpm
            pkgs.tree-sitter # the grammar CLI (no more npx)
          ];

          shellHook = ''
            echo "lish dev shell: zig $(zig version), node $(node --version), pnpm $(pnpm --version)"
            echo "(clone lish, lish-lsp, folio, tree-sitter-lish as siblings; then 'zig build' in any)"
          '';
        };
      });
}
