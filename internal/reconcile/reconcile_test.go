package reconcile

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/lxc/incus/v6/shared/api"
	"github.com/lxc/incus/v6/shared/cliconfig"
)

func TestLoadDesiredInstancesDefaults(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "instances.json")
	if err := os.WriteFile(path, []byte(`[{"name":"web","image":"images:ubuntu/24.04","type":"container","ensureRunning":true}]`), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	instances, err := loadDesiredInstances(path)
	if err != nil {
		t.Fatalf("load desired instances: %v", err)
	}

	if len(instances) != 1 {
		t.Fatalf("expected 1 instance, got %d", len(instances))
	}

	if instances[0].Profiles == nil || instances[0].Config == nil || instances[0].Devices == nil {
		t.Fatalf("expected nil collections to be defaulted: %#v", instances[0])
	}
}

func TestNormalizeDesiredConfigAddsMarker(t *testing.T) {
	t.Parallel()

	got := normalizeDesiredConfig(map[string]string{
		"limits.cpu": "2",
	}, "user.incus-nix.managed")

	if got["limits.cpu"] != "2" {
		t.Fatalf("expected original config to be preserved")
	}

	if got["user.incus-nix.managed"] != managedMarkerValue {
		t.Fatalf("expected managed marker to be set")
	}
}

func TestFilteredCurrentConfigDropsGeneratedKeys(t *testing.T) {
	t.Parallel()

	got := filteredCurrentConfig(map[string]string{
		"volatile.base_image":    "abc",
		"image.architecture":     "x86_64",
		"user.incus-nix.managed": "true",
		"limits.memory":          "1GiB",
		"security.nesting":       "true",
	}, "user.incus-nix.managed")

	if len(got) != 2 {
		t.Fatalf("expected 2 keys after filtering, got %d", len(got))
	}

	if got["limits.memory"] != "1GiB" || got["security.nesting"] != "true" {
		t.Fatalf("unexpected filtered config: %#v", got)
	}
}

func TestEqualDeviceMap(t *testing.T) {
	t.Parallel()

	left := map[string]map[string]string{
		"root": {
			"type": "disk",
			"path": "/",
			"pool": "default",
		},
	}

	right := map[string]map[string]string{
		"root": {
			"pool": "default",
			"type": "disk",
			"path": "/",
		},
	}

	if !equalDeviceMap(left, right) {
		t.Fatalf("expected device maps to compare equal")
	}
}

func TestParseImageSourceForDefaultRemotes(t *testing.T) {
	t.Parallel()

	cfg := cliconfig.DefaultConfig()

	source, err := parseImageSource(cfg, "images:ubuntu/24.04")
	if err != nil {
		t.Fatalf("parse image source: %v", err)
	}

	if source.Server != "https://images.linuxcontainers.org" {
		t.Fatalf("unexpected remote server: %q", source.Server)
	}

	if source.Protocol != "simplestreams" {
		t.Fatalf("unexpected protocol: %q", source.Protocol)
	}

	if source.Alias != "ubuntu/24.04" {
		t.Fatalf("unexpected alias: %q", source.Alias)
	}
}

func TestParseImageSourceForLocalFingerprint(t *testing.T) {
	t.Parallel()

	cfg := cliconfig.DefaultConfig()
	fp := "0123456789abcdef"

	source, err := parseImageSource(cfg, "local:"+fp)
	if err != nil {
		t.Fatalf("parse image source: %v", err)
	}

	if source.Server != "" || source.Protocol != "" {
		t.Fatalf("local source should not set remote fields: %#v", source)
	}

	if source.Fingerprint != fp {
		t.Fatalf("unexpected fingerprint: %q", source.Fingerprint)
	}
}

func TestNormalizeDesiredDevices(t *testing.T) {
	t.Parallel()

	got := normalizeDesiredDevices(map[string]DesiredDevice{
		"eth0": {
			Type: "nic",
			Properties: map[string]string{
				"network": "incusbr0",
				"name":    "eth0",
			},
		},
	})

	device := got["eth0"]
	if device["type"] != "nic" || device["network"] != "incusbr0" || device["name"] != "eth0" {
		t.Fatalf("unexpected normalized device: %#v", got)
	}
}

func TestTypeComparisonUsesExactStrings(t *testing.T) {
	t.Parallel()

	instance := api.Instance{Type: "container"}
	if instance.Type != "container" {
		t.Fatalf("unexpected instance type conversion")
	}
}
