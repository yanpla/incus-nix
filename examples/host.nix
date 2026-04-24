{ inputs, system, ... }:

{
  imports = [
    inputs.incus-nix.modules.incus-nix
  ];

  virtualisation.incus = {
    enable = true;
    package = inputs.nixpkgs.legacyPackages.${system}.incus-lts;
  };

  virtualisation.incus.instances = {
    web-server = {
      image = "images:ubuntu/24.04";
      type = "container";
      profiles = ["default"];
      config = {
        "limits.cpu" = "1";
        "limits.memory" = "512MiB";
      };
      ensureRunning = true;
    };

    dev-vm = {
      image = "images:debian/13";
      type = "virtual-machine";
      profiles = ["default"];
      config = {
        "limits.cpu" = "2";
        "limits.memory" = "2GiB";
      };
      devices.root = {
        type = "disk";
        properties = {
          path = "/";
          pool = "default";
          size = "20GiB";
        };
      };
      ensureRunning = true;
    };
  };
}