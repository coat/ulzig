{
  description = "A Zig library and small command line tool for compressing and decompressing Uxn LZ Format (ULZ) things.";

  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";

  outputs = {nixpkgs, ...}: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
  in
    builtins.foldl' nixpkgs.lib.recursiveUpdate {} (
      builtins.map (
        system: let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
          packages.${system}.default = pkgs.callPackage ./package.nix {};

          devShells.${system}.default = pkgs.mkShell {
            packages = with pkgs;
              [
                zig
              ]
              ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [kcov elfkickers]);
          };

          formatter.${system} = pkgs.alejandra;
        }
      )
      systems
    );
}
