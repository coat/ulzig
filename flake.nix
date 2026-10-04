{
  description = "A Zig library and small command line tool for compressing and decompressing Uxn LZ Format (ULZ) things.";

  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";

  inputs.zig.url = "github:mitchellh/zig-overlay";

  outputs = {
    nixpkgs,
    zig,
    ...
  }: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
  in
    builtins.foldl' nixpkgs.lib.recursiveUpdate {} (
      builtins.map (
        system: let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [zig.overlays.default];
          };
        in {
          packages.${system}.default = pkgs.callPackage ./package.nix {zig = pkgs.zigpkgs."0.17.0";};

          devShells.${system}.default = pkgs.mkShell {
            packages = with pkgs;
              [
                zigpkgs."0.17.0"
              ]
              ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [kcov elfkickers]);
          };

          formatter.${system} = pkgs.alejandra;
        }
      )
      systems
    );
}
