package reconcile

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"slices"
	"strings"

	incus "github.com/lxc/incus/v6/client"
	"github.com/lxc/incus/v6/shared/api"
	"github.com/lxc/incus/v6/shared/cliconfig"
)

const managedMarkerValue = "true"

type Config struct {
	InstanceDataFile string
	MarkerKey        string
	Prune            bool
	Logger           *log.Logger
}

type DesiredInstance struct {
	Name          string                   `json:"name"`
	Image         string                   `json:"image"`
	Type          string                   `json:"type"`
	Profiles      []string                 `json:"profiles"`
	Config        map[string]string        `json:"config"`
	Devices       map[string]DesiredDevice `json:"devices"`
	EnsureRunning bool                     `json:"ensureRunning"`
}

type DesiredDevice struct {
	Type       string            `json:"type"`
	Properties map[string]string `json:"properties"`
}

func Run(ctx context.Context, cfg Config) error {
	if cfg.Logger == nil {
		cfg.Logger = log.New(os.Stdout, "incus-nix: ", 0)
	}

	if cfg.InstanceDataFile == "" {
		return errors.New("INSTANCE_DATA_FILE is not set")
	}

	if cfg.MarkerKey == "" {
		return errors.New("MARKER_KEY is not set")
	}

	desired, err := loadDesiredInstances(cfg.InstanceDataFile)
	if err != nil {
		return err
	}

	server, err := incus.ConnectIncusUnix("", nil)
	if err != nil {
		return fmt.Errorf("connect to local Incus daemon: %w", err)
	}

	clientConfig, err := cliconfig.LoadConfig("")
	if err != nil {
		return fmt.Errorf("load Incus client config: %w", err)
	}

	cfg.Logger.Printf("Starting reconciliation")

	desiredNames := make(map[string]struct{}, len(desired))

	for _, spec := range desired {
		desiredNames[spec.Name] = struct{}{}
		cfg.Logger.Printf("Processing %s", spec.Name)

		if err := reconcileInstance(ctx, server, clientConfig, cfg, spec); err != nil {
			return err
		}
	}

	if cfg.Prune {
		if err := pruneInstances(ctx, server, cfg, desiredNames); err != nil {
			return err
		}
	}

	cfg.Logger.Printf("Reconciliation complete")
	return nil
}

func loadDesiredInstances(path string) ([]DesiredInstance, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read desired instance data %q: %w", path, err)
	}

	var instances []DesiredInstance
	if err := json.Unmarshal(raw, &instances); err != nil {
		return nil, fmt.Errorf("decode desired instance data %q: %w", path, err)
	}

	for i := range instances {
		if instances[i].Profiles == nil {
			instances[i].Profiles = []string{}
		}

		if instances[i].Config == nil {
			instances[i].Config = map[string]string{}
		}

		if instances[i].Devices == nil {
			instances[i].Devices = map[string]DesiredDevice{}
		}
	}

	return instances, nil
}

func reconcileInstance(ctx context.Context, server incus.InstanceServer, clientConfig *cliconfig.Config, cfg Config, spec DesiredInstance) error {
	instance, etag, err := server.GetInstance(spec.Name)
	if err != nil {
		if !api.StatusErrorCheck(err, http.StatusNotFound) {
			return fmt.Errorf("get instance %q: %w", spec.Name, err)
		}

		cfg.Logger.Printf("Creating %s from %s", spec.Name, spec.Image)
		if err := createInstance(ctx, server, clientConfig, cfg, spec); err != nil {
			return err
		}

		instance, etag, err = server.GetInstance(spec.Name)
		if err != nil {
			return fmt.Errorf("get created instance %q: %w", spec.Name, err)
		}
	}

	if string(instance.Type) != spec.Type {
		return fmt.Errorf("type mismatch for %s: have %s, want %s", spec.Name, instance.Type, spec.Type)
	}

	currentProfiles := append([]string(nil), instance.Profiles...)
	desiredProfiles := append([]string(nil), spec.Profiles...)
	currentConfig := filteredCurrentConfig(instance.Config, cfg.MarkerKey)
	desiredConfig := normalizeDesiredConfig(spec.Config, cfg.MarkerKey)
	currentDevices := normalizeLocalDevices(instance.Devices)
	desiredDevices := normalizeDesiredDevices(spec.Devices)

	if !slices.Equal(currentProfiles, desiredProfiles) || !equalStringMap(currentConfig, desiredConfig) || !equalDeviceMap(currentDevices, desiredDevices) {
		cfg.Logger.Printf("Updating %s", spec.Name)
		put := instance.Writable()
		put.Profiles = desiredProfiles
		put.Config = desiredConfig
		put.Devices = desiredDevices

		op, err := server.UpdateInstance(spec.Name, put, etag)
		if err != nil {
			return fmt.Errorf("update instance %q: %w", spec.Name, err)
		}

		if err := op.WaitContext(ctx); err != nil {
			return fmt.Errorf("wait for update of %q: %w", spec.Name, err)
		}
	}

	if err := reconcileState(ctx, server, cfg, spec); err != nil {
		return err
	}

	return nil
}

func createInstance(ctx context.Context, server incus.InstanceServer, clientConfig *cliconfig.Config, cfg Config, spec DesiredInstance) error {
	source, err := parseImageSource(clientConfig, spec.Image)
	if err != nil {
		return fmt.Errorf("resolve image %q for %q: %w", spec.Image, spec.Name, err)
	}

	req := api.InstancesPost{
		InstancePut: api.InstancePut{
			Profiles: append([]string(nil), spec.Profiles...),
			Config:   normalizeDesiredConfig(spec.Config, cfg.MarkerKey),
			Devices:  normalizeDesiredDevices(spec.Devices),
		},
		Name:   spec.Name,
		Type:   api.InstanceType(spec.Type),
		Source: source,
		Start:  false,
	}

	op, err := server.CreateInstance(req)
	if err != nil {
		return fmt.Errorf("create instance %q: %w", spec.Name, err)
	}

	if err := op.WaitContext(ctx); err != nil {
		return fmt.Errorf("wait for create of %q: %w", spec.Name, err)
	}

	return nil
}

func reconcileState(ctx context.Context, server incus.InstanceServer, cfg Config, spec DesiredInstance) error {
	state, etag, err := server.GetInstanceState(spec.Name)
	if err != nil {
		return fmt.Errorf("get instance state %q: %w", spec.Name, err)
	}

	if spec.EnsureRunning {
		if state.Status == "Running" {
			cfg.Logger.Printf("%s already running", spec.Name)
			return nil
		}

		cfg.Logger.Printf("Starting %s", spec.Name)
		op, err := server.UpdateInstanceState(spec.Name, api.InstanceStatePut{
			Action:  "start",
			Timeout: -1,
		}, etag)
		if err != nil {
			return fmt.Errorf("start instance %q: %w", spec.Name, err)
		}

		if err := op.WaitContext(ctx); err != nil {
			return fmt.Errorf("wait for start of %q: %w", spec.Name, err)
		}

		return nil
	}

	if state.Status != "Running" {
		cfg.Logger.Printf("%s already stopped", spec.Name)
		return nil
	}

	cfg.Logger.Printf("Stopping %s", spec.Name)
	op, err := server.UpdateInstanceState(spec.Name, api.InstanceStatePut{
		Action:  "stop",
		Timeout: -1,
		Force:   true,
	}, etag)
	if err != nil {
		return fmt.Errorf("stop instance %q: %w", spec.Name, err)
	}

	if err := op.WaitContext(ctx); err != nil {
		return fmt.Errorf("wait for stop of %q: %w", spec.Name, err)
	}

	return nil
}

func pruneInstances(ctx context.Context, server incus.InstanceServer, cfg Config, desiredNames map[string]struct{}) error {
	instances, err := server.GetInstances(api.InstanceTypeAny)
	if err != nil {
		return fmt.Errorf("list instances for pruning: %w", err)
	}

	for _, instance := range instances {
		if _, ok := desiredNames[instance.Name]; ok {
			continue
		}

		if instance.Config[cfg.MarkerKey] != managedMarkerValue {
			cfg.Logger.Printf("Skipping unmanaged instance %s", instance.Name)
			continue
		}

		cfg.Logger.Printf("Deleting managed instance %s", instance.Name)
		op, err := server.DeleteInstance(instance.Name)
		if err != nil {
			return fmt.Errorf("delete instance %q: %w", instance.Name, err)
		}

		if err := op.WaitContext(ctx); err != nil {
			return fmt.Errorf("wait for delete of %q: %w", instance.Name, err)
		}
	}

	return nil
}

func parseImageSource(clientConfig *cliconfig.Config, image string) (api.InstanceSource, error) {
	remoteName, imageName, err := clientConfig.ParseRemote(image)
	if err != nil {
		return api.InstanceSource{}, err
	}

	remote, ok := clientConfig.Remotes[remoteName]
	if !ok {
		return api.InstanceSource{}, fmt.Errorf("unknown remote %q", remoteName)
	}

	source := api.InstanceSource{
		Type: "image",
	}

	if isFingerprint(imageName) {
		source.Fingerprint = imageName
	} else {
		source.Alias = imageName
	}

	if remoteName == "local" || strings.HasPrefix(remote.Addr, "unix://") {
		return source, nil
	}

	source.Server = remote.Addr
	source.Protocol = remote.Protocol
	source.Project = remote.Project

	return source, nil
}

func normalizeDesiredConfig(config map[string]string, markerKey string) map[string]string {
	out := make(map[string]string, len(config)+1)
	for key, value := range config {
		out[key] = value
	}

	out[markerKey] = managedMarkerValue
	return out
}

func filteredCurrentConfig(config map[string]string, markerKey string) map[string]string {
	out := make(map[string]string, len(config))
	for key, value := range config {
		if key == markerKey {
			continue
		}

		if strings.HasPrefix(key, "volatile.") || strings.HasPrefix(key, "image.") {
			continue
		}

		out[key] = value
	}

	return out
}

func normalizeDesiredDevices(devices map[string]DesiredDevice) map[string]map[string]string {
	out := make(map[string]map[string]string, len(devices))
	for name, device := range devices {
		normalized := make(map[string]string, len(device.Properties)+1)
		normalized["type"] = device.Type
		for key, value := range device.Properties {
			normalized[key] = value
		}
		out[name] = normalized
	}

	return out
}

func normalizeLocalDevices(devices map[string]map[string]string) map[string]map[string]string {
	out := make(map[string]map[string]string, len(devices))
	for name, device := range devices {
		normalized := make(map[string]string, len(device))
		for key, value := range device {
			normalized[key] = value
		}
		out[name] = normalized
	}

	return out
}

func equalStringMap(left, right map[string]string) bool {
	if len(left) != len(right) {
		return false
	}

	for key, leftValue := range left {
		rightValue, ok := right[key]
		if !ok || rightValue != leftValue {
			return false
		}
	}

	return true
}

func equalDeviceMap(left, right map[string]map[string]string) bool {
	if len(left) != len(right) {
		return false
	}

	for name, leftDevice := range left {
		rightDevice, ok := right[name]
		if !ok || !equalStringMap(leftDevice, rightDevice) {
			return false
		}
	}

	return true
}

func isFingerprint(value string) bool {
	if len(value) < 12 || len(value)%2 != 0 {
		return false
	}

	_, err := hex.DecodeString(value)
	return err == nil
}
