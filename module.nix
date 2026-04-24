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

  reconcileScript = pkgs.writeShellApplication {
    name = "incus-nix-reconcile";
    runtimeInputs = [
      incusPkg
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      set -uo pipefail

      log() {
        echo "incus-nix: $*"
      }

      fail() {
        log "ERROR: $*"
        exit 1
      }

      normalize_json() {
        jq -cS '.' <<<"$1"
      }

      instance_exists() {
        local name="$1"

        jq -e --arg name "$name" '.[] | select(.name == $name)' \
          <<<"$existing_json" >/dev/null
      }

      get_instance_meta() {
        local name="$1"

        incus query "/1.0/instances/$name" | jq -c '.metadata'
      }

      create_instance() {
        local name="$1"
        local image="$2"
        local type="$3"
        local profiles_json="$4"

        local -a args=()
        args+=(--quiet)

        if [[ "$type" == "virtual-machine" ]]; then
          args+=(--vm)
        fi

        if [[ "$(jq 'length' <<<"$profiles_json")" -eq 0 ]]; then
          args+=(--no-profiles)
        else
          while IFS= read -r profile; do
            args+=(-p "$profile")
          done < <(jq -r '.[]' <<<"$profiles_json")
        fi

        log "Launching $name from $image with type $type"
        local output
        if output=$(incus launch "$image" "$name" "''${args[@]}" 2>&1); then
          log "Created $name successfully"
          return 0
        else
          log "ERROR: Failed to create $name"
          log "Output: $output"
          return 1
        fi
      }

      reconcile_profiles() {
        local name="$1"
        local profiles_json="$2"
        local profiles_csv

        profiles_csv="$(jq -r 'join(",")' <<<"$profiles_json")"

        log "Assigning profiles for $name: ''${profiles_csv:-<none>}"
        incus profile assign "$name" "$profiles_csv"
      }

      reconcile_config() {
        local name="$1"
        local desired_config_json="$2"
        local meta="$3"
        local current_config_json
        local key
        local value
        local current_value

        current_config_json="$(
          jq -c --arg markerKey "$MARKER_KEY" '
            (.config // {})
            | with_entries(
              select(
                (.key | startswith("volatile.") | not)
                and (.key | startswith("image.") | not)
                and (.key != $markerKey)
              )
            )
          ' <<<"$meta"
        )"

        while IFS= read -r key; do
          if ! jq -e --arg key "$key" 'has($key)' \
            <<<"$desired_config_json" >/dev/null; then
            log "Unsetting config $name.$key"
            incus config unset "$name" "$key"
          fi
        done < <(jq -r 'keys[]?' <<<"$current_config_json")

        while IFS=$'\t' read -r key value; do
          current_value="$(
            jq -r --arg key "$key" '.[$key] // empty' \
              <<<"$current_config_json"
          )"

          if [[ "$current_value" != "$value" ]]; then
            log "Setting config $name.$key"
            incus config set "$name" "$key=$value"
          fi
        done < <(
          jq -r '
            to_entries[]
            | [.key, (.value | tostring)]
            | @tsv
          ' <<<"$desired_config_json"
        )

        incus config set "$name" "$MARKER_KEY=true"
      }

      add_device() {
        local instance="$1"
        local device_name="$2"
        local device_json="$3"
        local device_type
        local -a args=()

        device_type="$(jq -r '.type' <<<"$device_json")"

        while IFS=$'\t' read -r key value; do
          if [[ "$key" != "type" ]]; then
            args+=("$key=$value")
          fi
        done < <(
          jq -r '
            to_entries[]
            | select(.key != "type")
            | [.key, (.value | tostring)]
            | @tsv
          ' <<<"$device_json"
        )

        incus config device add "$instance" "$device_name" "$device_type" \
          "''${args[@]}"
      }

      reconcile_devices() {
        local name="$1"
        local desired_devices_json="$2"
        local meta="$3"
        local current_devices_json
        local device_name
        local desired_device_json
        local current_device_json

        current_devices_json="$(jq -c '.devices // {}' <<<"$meta")"

        while IFS= read -r device_name; do
          if ! jq -e --arg name "$device_name" 'has($name)' \
            <<<"$desired_devices_json" >/dev/null; then
            log "Removing device $name.$device_name"
            incus config device remove "$name" "$device_name"
          fi
        done < <(jq -r 'keys[]?' <<<"$current_devices_json")

        while IFS= read -r device_name; do
          desired_device_json="$(
            jq -c --arg name "$device_name" '.[$name]' \
              <<<"$desired_devices_json"
          )"

          current_device_json="$(
            jq -c --arg name "$device_name" '.[$name] // null' \
              <<<"$current_devices_json"
          )"

          if [[ "$current_device_json" == "null" ]]; then
            log "Adding device $name.$device_name"
            add_device "$name" "$device_name" "$desired_device_json"
            continue
          fi

          current_norm="$(normalize_json "$current_device_json")"
          desired_norm="$(normalize_json "$desired_device_json")"
          if [[ "$current_norm" != "$desired_norm" ]]; then
            log "Replacing device $name.$device_name"
            incus config device remove "$name" "$device_name"
            add_device "$name" "$device_name" "$desired_device_json"
          fi
        done < <(jq -r 'keys[]?' <<<"$desired_devices_json")
      }

      reconcile_state() {
        local name="$1"
        local ensure_running="$2"
        local meta
        local status

        meta="$(get_instance_meta "$name")"
        status="$(jq -r '.status // "Unknown"' <<<"$meta")"

        if [[ "$ensure_running" == "true" ]]; then
          if [[ "$status" != "Running" ]]; then
            log "Starting $name"
            incus start "$name"
          else
            log "$name already running"
          fi
        else
          if [[ "$status" == "Running" ]]; then
            log "Stopping $name"
            incus stop "$name"
          else
            log "$name already stopped"
          fi
        fi
      }

      prune_instances() {
        local all_instances_json
        local name
        local meta
        local managed

        if [[ "$PRUNE" != "true" ]]; then
          return 0
        fi

        all_instances_json="$(incus list --format json 2>/dev/null || printf '[]\n')"

        while IFS= read -r name; do
          if [[ -z "$name" ]]; then
            continue
          fi

          if [[ "''${desired_names[$name]:-0}" == "1" ]]; then
            continue
          fi

          meta="$(get_instance_meta "$name")"
          managed="$(
            jq -r --arg key "$MARKER_KEY" '.config[$key] // "false"' \
              <<<"$meta"
          )"

          if [[ "$managed" == "true" ]]; then
            log "Deleting managed instance $name"
            incus delete --force "$name"
          else
            log "Skipping unmanaged instance $name"
          fi
        done < <(jq -r '.[].name' <<<"$all_instances_json")
      }

      if [[ ! -f "$INSTANCE_DATA_FILE" ]]; then
        log "Instance data file not found: $INSTANCE_DATA_FILE"
        exit 1
      fi

      log "Starting reconciliation"
      existing_json="$(incus list --format json 2>/dev/null || printf '[]\n')"
      desired_json="$(<"$INSTANCE_DATA_FILE")"

      declare -A desired_names=()
      failed=0

      while IFS= read -r spec; do
        name="$(jq -r '.name' <<<"$spec")"
        image="$(jq -r '.image' <<<"$spec")"
        desired_type="$(jq -r '.type' <<<"$spec")"
        profiles_json="$(jq -c '.profiles // []' <<<"$spec")"
        desired_config_json="$(jq -c '.config // {}' <<<"$spec")"
        desired_devices_json="$(jq -c '.devices // {}' <<<"$spec")"
        ensure_running="$(jq -r '.ensureRunning // true' <<<"$spec")"

        desired_names["$name"]=1

        log "Processing $name"

        if ! instance_exists "$name"; then
          log "Creating $name from $image"
          if ! create_instance "$name" "$image" "$desired_type" "$profiles_json"; then
            log "ERROR: Failed to create $name, skipping this instance"
            failed=1
            continue
          fi
          existing_json="$(incus list --format json 2>/dev/null || printf '[]\n')"
        fi

        meta="$(get_instance_meta "$name")"
        current_type="$(jq -r '.type' <<<"$meta")"

        if [[ "$current_type" != "$desired_type" ]]; then
          log "Type mismatch for $name: have $current_type, want $desired_type"
          continue
        fi

        reconcile_profiles "$name" "$profiles_json"
        meta="$(get_instance_meta "$name")"

        reconcile_config "$name" "$desired_config_json" "$meta"
        meta="$(get_instance_meta "$name")"

        reconcile_devices "$name" "$desired_devices_json" "$meta"
        reconcile_state "$name" "$ensure_running"
      done < <(jq -c '.[]' <<<"$desired_json")

      if [[ "$failed" == "1" ]]; then
        fail "One or more instances failed to create"
      fi

      prune_instances

      log "Reconciliation complete"
    '';
  };
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
        reconcileScript
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Environment = [
          "INSTANCE_DATA_FILE=${instanceDataFile}"
          "MARKER_KEY=${cfg.managedMarkerKey}"
          "PRUNE=${lib.boolToString cfg.pruneInstances}"
        ];
        ExecStart = lib.getExe reconcileScript;
      };
    };
  };
}
