# incus-nix

Declarative Incus instances for NixOS.

Define your Incus containers and VMs in NixOS configuration and let `nixos-rebuild` manage their lifecycle.

## Usage

### 1. Add to flake inputs

```nix
{
  inputs.incus-nix.url = "path:./incus-nix";
  # or for a remote flake:
  # incus-nix.url = "github:yourname/incus-nix";
}
```

### 2. Import the module

```nix
{
  imports = [ incus-nix.modules.incus-nix ];
}
```

### 3. Configure instances

```nix
{
  virtualisation.incus = {
    enable = true;

    instances = {
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
        config = {
          "limits.cpu" = "2";
          "limits.memory" = "2GiB";
        };
        ensureRunning = true;
      };
    };
  };
}
```

## Options

### `virtualisation.incus.instances`

Attribute set of instance configurations.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `image` | string | required | Image to use (e.g., `images:ubuntu/24.04`) |
| `type` | `"container"` / `"virtual-machine"` | `"container"` | Instance type |
| `profiles` | list of strings | `["default"]` | Incus profiles to assign |
| `config` | attribute set | `{}` | Instance config key-value pairs |
| `devices` | attribute set | `{}` | Instance-local devices |
| `ensureRunning` | boolean | `true` | Whether to keep instance running |

### `virtualisation.incus.pruneInstances`

Boolean flag to delete managed instances removed from Nix config.

```nix
{
  virtualisation.incus.pruneInstances = true;
}
```

## How it works

- Instance data is written to a JSON file at activation time
- A systemd oneshot service runs after `incus.service` to reconcile state
- Instances are created, config/devices reconciled, and started as needed
- A marker key (`user.incus-nix.managed`) marks instances as managed
- When `pruneInstances = true`, managed instances not in Nix config are deleted

## Running

```sh
sudo nixos-rebuild switch --flake .#your-host
```

The `incus-nix-reconcile` service runs automatically after the switch. You can also run it manually:

```sh
sudo systemctl start incus-nix-reconcile
```

Check status:

```sh
incus list
```