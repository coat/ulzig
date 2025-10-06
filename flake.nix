{
  description = "ulzig";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
  };

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
                elfkickers
                zig_0_15
              ]
              ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [kcov]);
          };

          formatter.${system} = pkgs.alejandra;
        }
      )
      systems
    );
}
