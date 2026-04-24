{ buildGoModule, lib }:

buildGoModule {
  pname = "incus-nix-reconcile";
  version = "0.1.0";
  src = ./.;
  subPackages = [ "cmd/incus-nix-reconcile" ];
  vendorHash = "sha256-b7RIF1DGYTYs2qwUe8XyEJpwvuMuGcZnwhUwNbeto2Y=";

  meta.mainProgram = "incus-nix-reconcile";
}
