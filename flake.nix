{
  description = "Declarative Incus instances for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      modules.incus-nix = ./module.nix;

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
        in
        {
          incus-nix-reconcile = pkgs.callPackage ./package.nix { };
          default = pkgs.callPackage ./package.nix { };
        }
      );

      checks = forAllSystems (
        system:
        {
          incus-nix-reconcile = self.packages.${system}.incus-nix-reconcile;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              go
              gopls
            ];
          };
        }
      );
    };
}
