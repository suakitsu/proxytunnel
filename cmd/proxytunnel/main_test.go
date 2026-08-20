package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadConfigAppliesUsableDefaults(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.local.json")
	if err := os.WriteFile(configPath, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := loadConfig(configPath)
	if err != nil {
		t.Fatal(err)
	}
	wants := map[string]string{
		"listen":          "127.0.0.1:9191",
		"controller_url":  "http://127.0.0.1:9090",
		"provider_name":   "default",
		"group_name":      "PROXY",
		"allowed_cidr":    "127.0.0.0/8",
		"data_dir":        filepath.Join(dir, "var"),
		"history_dir":     filepath.Join(dir, "var", "history"),
		"candidate_state": filepath.Join(dir, "var", "state", "candidate-selection.json"),
	}
	got := map[string]string{
		"listen":          cfg.Listen,
		"controller_url":  cfg.ControllerURL,
		"provider_name":   cfg.ProviderName,
		"group_name":      cfg.GroupName,
		"allowed_cidr":    cfg.AllowedCIDR,
		"data_dir":        cfg.DataDir,
		"history_dir":     cfg.HistoryDir,
		"candidate_state": cfg.CandidateStateFile,
	}
	for key, want := range wants {
		if got[key] != want {
			t.Errorf("%s = %q, want %q", key, got[key], want)
		}
	}
}

func TestLoadConfigResolvesPathsRelativeToConfig(t *testing.T) {
	dir := t.TempDir()
	configDir := filepath.Join(dir, "settings")
	if err := os.MkdirAll(configDir, 0o750); err != nil {
		t.Fatal(err)
	}
	payload, err := json.Marshal(map[string]any{
		"data_dir":               "runtime",
		"controller_secret_file": "secrets/controller.secret",
	})
	if err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(configDir, "config.json")
	if err := os.WriteFile(configPath, payload, 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := loadConfig(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DataDir != filepath.Join(configDir, "runtime") {
		t.Fatalf("data_dir = %q", cfg.DataDir)
	}
	if cfg.ControllerSecretFile != filepath.Join(configDir, "secrets", "controller.secret") {
		t.Fatalf("controller_secret_file = %q", cfg.ControllerSecretFile)
	}
}

func TestLoadConfigRejectsInvalidNetworkBoundary(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	if err := os.WriteFile(configPath, []byte(`{"allowed_cidr":"everyone"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadConfig(configPath); err == nil || !strings.Contains(err.Error(), "allowed_cidr") {
		t.Fatalf("loadConfig error = %v, want allowed_cidr error", err)
	}
}

func TestReplaceFileReplacesExistingDestination(t *testing.T) {
	dir := t.TempDir()
	destination := filepath.Join(dir, "state.json")
	temporary := destination + ".tmp"
	if err := os.WriteFile(destination, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(temporary, []byte("new"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := replaceFile(temporary, destination); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "new" {
		t.Fatalf("destination = %q, want new", data)
	}
}

func TestAssignCountryPortsPreservesPreviousPort(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "country-ports.json")
	previous := CountryPortDocument{Assignments: []CountryPortAssignment{{Code: "US", Port: 17904, Enabled: true}}}
	if err := writeCountryPortDocument(statePath, previous); err != nil {
		t.Fatal(err)
	}
	monitor := &Monitor{cfg: Config{CountryPortStateFile: statePath, CountryPortBase: 17901}}
	stable := map[string][]string{"DE": {"de-node"}, "US": {"us-a", "us-b"}}
	assignments, err := monitor.assignCountryPorts([]string{"DE", "US"}, stable)
	if err != nil {
		t.Fatal(err)
	}
	ports := map[string]int{}
	for _, assignment := range assignments {
		ports[assignment.Code] = assignment.Port
	}
	if ports["US"] != 17904 {
		t.Fatalf("US port = %d, want 17904", ports["US"])
	}
	if ports["DE"] != 17901 {
		t.Fatalf("DE port = %d, want 17901", ports["DE"])
	}
}

func TestRenderProbeConfigUsesOnlyIsolatedPortsAndStableFilter(t *testing.T) {
	dir := t.TempDir()
	monitor := &Monitor{
		cfg: Config{
			ProbeConfigFile:   filepath.Join(dir, "config.yaml"),
			ProbeProviderFile: filepath.Join(dir, "provider.yaml"),
			ProbeProviderName: "country-probe",
			ProbeGroupName:    "GEO-PROBE",
		},
		probeSecret: "test-only-secret",
	}
	assignments := []CountryPortAssignment{{Code: "US", Name: "美国", Port: 17901, NodeCount: 2, Enabled: true}}
	stable := map[string][]string{"US": {"US node (A)", "US.node+B"}}
	config, err := monitor.renderProbeConfig(assignments, stable)
	if err != nil {
		t.Fatal(err)
	}
	text := string(config)
	for _, required := range []string{
		"mixed-port: 17891",
		"external-controller: 127.0.0.1:19091",
		"port: 17901",
		"listen: 0.0.0.0",
		"proxy: \"COUNTRY-US\"",
		"type: load-balance",
		"strategy: round-robin",
		"use:\n      - country-probe",
		`US node \\(A\\)`,
		`US\\.node\\+B`,
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("generated config is missing %q\n%s", required, text)
		}
	}
	for _, forbidden := range []string{"7890", "9100", "19090"} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("generated config unexpectedly contains production port %s", forbidden)
		}
	}
}

func TestWriteValidationConfig(t *testing.T) {
	output := os.Getenv("PROXYTUNNEL_VALIDATION_CONFIG")
	if output == "" {
		t.Skip("PROXYTUNNEL_VALIDATION_CONFIG is not set")
	}
	monitor := &Monitor{
		cfg: Config{
			ProbeConfigFile:   filepath.Join(filepath.Dir(output), "config-validation.yaml"),
			ProbeProviderFile: filepath.Join(filepath.Dir(output), "provider.yaml"),
			ProbeProviderName: "country-probe",
			ProbeGroupName:    "GEO-PROBE",
		},
		probeSecret: "validation-only-secret",
	}
	assignments := []CountryPortAssignment{{Code: "US", Name: "美国", Port: 17901, NodeCount: 2, Enabled: true}}
	stable := map[string][]string{"US": {"validation-node-a", "validation-node-b"}}
	config, err := monitor.renderProbeConfig(assignments, stable)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(output, config, 0o600); err != nil {
		t.Fatal(err)
	}
}
