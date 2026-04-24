{
  description = "Declarative Incus instances for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    {
      modules.incus-nix = ./module.nix;
    };
}
