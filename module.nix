{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.virtualisation.incus;

  incusPkg = cfg.package or pkgs.incus;

  instanceType = lib.types.enum [
    "container"
    "virtual-machine"
  ];

  flattenDevice =
    device:
    {
      inherit (device) type;
    }
    // device.properties;

  instancesJson = builtins.toJSON (
    lib.mapAttrsToList (name: instance: {
      inherit name;
      image = instance.image;
      type = instance.type;
      profiles = instance.profiles;
      config = instance.config;
      devices = lib.mapAttrs (_: flattenDevice) instance.devices;
      ensureRunning = instance.ensureRunning;
    }) cfg.instances
  );

  instanceDataFile = pkgs.writeText "incus-instances.json" instancesJson;

  reconcilePackage = pkgs.callPackage ./package.nix { };
in
{
  options.virtualisation.incus = {
    instances = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { ... }:
          {
            options = {
              image = lib.mkOption {
                type = lib.types.str;
                description = ''
                  Image to use when creating the instance, for example
                  `images:ubuntu/24.04`.

                  This is only used when the instance does not already exist.
                  Existing instances are not automatically rebuilt when this
                  value changes.
                '';
              };

              type = lib.mkOption {
                type = instanceType;
                default = "container";
                description = "Whether the instance is a container or VM.";
              };

              profiles = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ "default" ];
                description = ''
                  Exact profile list to assign to the instance.
                '';
              };

              config = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = { };
                description = ''
                  Instance-local config keys to reconcile with
                  `incus config set/unset`.
                '';
              };

              devices = lib.mkOption {
                type = lib.types.attrsOf (
                  lib.types.submodule (
                    { ... }:
                    {
                      options = {
                        type = lib.mkOption {
                          type = lib.types.str;
                          description = "Device type, for example `disk` or `nic`.";
                        };

                        properties = lib.mkOption {
                          type = lib.types.attrsOf lib.types.str;
                          default = { };
                          description = "Device properties.";
                        };
                      };
                    }
                  )
                );
                default = { };
                description = ''
                  Instance-local devices to reconcile.

                  Note that overriding devices inherited from profiles can still be
                  tricky in Incus, so profile-defined devices and instance-local
                  devices are best kept distinct.
                '';
              };

              ensureRunning = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = ''
                  Whether the instance should be running after reconciliation.
                '';
              };
            };
          }
        )
      );

      default = { };

      description = "Declarative Incus instances.";

      example = lib.literalExample ''
        {
          web-server = {
            image = "images:ubuntu/24.04";
            profiles = [ "default" ];
            config = {
              "limits.cpu" = "1";
              "limits.memory" = "512MiB";
            };
          };

          dev-vm = {
            image = "images:debian/13";
            type = "virtual-machine";
            profiles = [ "default" ];
            config = {
              "limits.cpu" = "2";
              "limits.memory" = "2GiB";
            };
            ensureRunning = true;
          };
        }
      '';
    };

    pruneInstances = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to delete instances that were previously created and marked as
        managed by this module, but are no longer present in the Nix config.

        Unmanaged Incus instances are never deleted.
      '';
    };

    managedMarkerKey = lib.mkOption {
      type = lib.types.str;
      default = "user.incus-nix.managed";
      description = ''
        Config key used to mark instances as managed by this module.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && (cfg.instances != { } || cfg.pruneInstances)) {
    systemd.services.incus-nix-reconcile = {
      description = "Reconcile declarative Incus instances";
      wantedBy = [ "multi-user.target" ];
      requires = [ "incus.service" ];
      after = [ "incus.service" ];

      restartIfChanged = true;
      restartTriggers = [
        instanceDataFile
        reconcilePackage
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Environment = [
          "INSTANCE_DATA_FILE=${instanceDataFile}"
          "MARKER_KEY=${cfg.managedMarkerKey}"
          "PRUNE=${lib.boolToString cfg.pruneInstances}"
        ];
        ExecStart = lib.getExe reconcilePackage;
      };
    };
  };
}
