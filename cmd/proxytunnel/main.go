package main

import (
	"bufio"
	"bytes"
	"context"
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"os/signal"
)

//go:embed web/index.html web/logo.svg
var staticFiles embed.FS

const platformVersion = "0.1.0-alpha.1"

type Config struct {
	DataDir                string `json:"data_dir"`
	Listen                 string `json:"listen"`
	ControllerURL          string `json:"controller_url"`
	ControllerSecretFile   string `json:"controller_secret_file"`
	ProviderName           string `json:"provider_name"`
	GroupName              string `json:"group_name"`
	CloudflareHealthURL    string `json:"cloudflare_health_url"`
	ProxyURL               string `json:"proxy_url"`
	EgressTraceURL         string `json:"egress_trace_url"`
	ProxyConfigFile        string `json:"proxy_config_file"`
	ProviderFile           string `json:"provider_file"`
	HistoryDir             string `json:"history_dir"`
	LogFile                string `json:"log_file"`
	ProxyTaskName          string `json:"proxy_task_name"`
	AllowedCIDR            string `json:"allowed_cidr"`
	PollSeconds            int    `json:"poll_seconds"`
	EgressSampleSeconds    int    `json:"egress_sample_seconds"`
	HistorySeconds         int    `json:"history_seconds"`
	RetentionDays          int    `json:"retention_days"`
	ProbeControllerURL     string `json:"probe_controller_url"`
	ProbeSecretFile        string `json:"probe_secret_file"`
	ProbeProviderName      string `json:"probe_provider_name"`
	ProbeGroupName         string `json:"probe_group_name"`
	ProbeProxyURL          string `json:"probe_proxy_url"`
	ProbeTraceURL          string `json:"probe_trace_url"`
	ProbeResultFile        string `json:"probe_result_file"`
	ProbeConfigFile        string `json:"probe_config_file"`
	ProbeProviderFile      string `json:"probe_provider_file"`
	ProbeTaskName          string `json:"probe_task_name"`
	MihomoExecutable       string `json:"mihomo_executable"`
	CountryPortStateFile   string `json:"country_port_state_file"`
	CountryPortBase        int    `json:"country_port_base"`
	CandidateStateFile     string `json:"candidate_state_file"`
	CloudflareOpsURL       string `json:"cloudflare_ops_url"`
	CloudflareOpsTokenFile string `json:"cloudflare_ops_token_file"`
}

type ProxyHistory struct {
	Time  string `json:"time"`
	Delay int    `json:"delay"`
}

type ProviderProxy struct {
	Name    string         `json:"name"`
	Type    string         `json:"type"`
	Alive   bool           `json:"alive"`
	History []ProxyHistory `json:"history"`
}

type ProviderResponse struct {
	Name        string          `json:"name"`
	VehicleType string          `json:"vehicleType"`
	UpdatedAt   string          `json:"updatedAt"`
	Proxies     []ProviderProxy `json:"proxies"`
}

type ConnectionsResponse struct {
	DownloadTotal int64             `json:"downloadTotal"`
	UploadTotal   int64             `json:"uploadTotal"`
	Connections   []json.RawMessage `json:"connections"`
}

type GroupResponse struct {
	Name string   `json:"name"`
	Type string   `json:"type"`
	Now  string   `json:"now"`
	All  []string `json:"all"`
}

type CloudflareHealth struct {
	Status              string `json:"status"`
	Service             string `json:"service"`
	UpstreamVersion     string `json:"upstream_version"`
	Build               string `json:"build"`
	IdentityCount       int    `json:"identity_count"`
	ProxyMode           string `json:"proxy_mode"`
	LocalNodeGeneration *bool  `json:"local_node_generation"`
	Rotation            struct {
		Strategy         string `json:"strategy"`
		ProxyConcurrency int    `json:"proxy_concurrency"`
	} `json:"rotation"`
	KV struct {
		Status string  `json:"status"`
		ReadMS float64 `json:"read_ms"`
	} `json:"kv"`
	Colo      string `json:"colo"`
	Timestamp string `json:"timestamp"`
}

type NodeStatus struct {
	Name             string  `json:"name"`
	Type             string  `json:"type"`
	CountryCode      string  `json:"country_code"`
	CountryName      string  `json:"country_name"`
	CountrySource    string  `json:"country_source"`
	Alive            bool    `json:"alive"`
	DelayMS          int     `json:"delay_ms"`
	LastCheckAt      string  `json:"last_check_at"`
	EgressReachable  bool    `json:"egress_reachable"`
	EgressIP         string  `json:"egress_ip,omitempty"`
	EgressColo       string  `json:"egress_colo,omitempty"`
	EgressLatencyMS  int64   `json:"egress_latency_ms"`
	EgressCheckedAt  string  `json:"egress_checked_at,omitempty"`
	EgressProbeError string  `json:"egress_probe_error,omitempty"`
	CountryStable    bool    `json:"country_stable"`
	CountrySamples   int     `json:"country_samples"`
	DownloadMbps     float64 `json:"download_mbps"`
	UploadMbps       float64 `json:"upload_mbps"`
	SpeedCheckedAt   string  `json:"speed_checked_at,omitempty"`
}

type ProbeNodeResult struct {
	Name           string  `json:"name"`
	ProviderAlive  bool    `json:"provider_alive"`
	Reachable      bool    `json:"reachable"`
	Country        string  `json:"country"`
	Colo           string  `json:"colo"`
	EgressIP       string  `json:"egress_ip"`
	LatencyMS      int64   `json:"latency_ms"`
	CheckedAt      string  `json:"checked_at"`
	Error          string  `json:"error"`
	CountryStable  bool    `json:"country_stable"`
	StableSamples  int     `json:"stable_samples"`
	DownloadMbps   float64 `json:"download_mbps"`
	UploadMbps     float64 `json:"upload_mbps"`
	SpeedCheckedAt string  `json:"speed_checked_at"`
}

type ProbeCountryCount struct {
	Code  string `json:"code"`
	Count int    `json:"count"`
}

type ProbeDocument struct {
	GeneratedAt string              `json:"generated_at"`
	Total       int                 `json:"total"`
	Tested      int                 `json:"tested"`
	Reachable   int                 `json:"reachable"`
	Stable      int                 `json:"stable"`
	Countries   []ProbeCountryCount `json:"countries"`
	Nodes       []ProbeNodeResult   `json:"nodes"`
}

type ProbeStatus struct {
	Enabled     bool                `json:"enabled"`
	Running     bool                `json:"running"`
	StartedAt   string              `json:"started_at,omitempty"`
	FinishedAt  string              `json:"finished_at,omitempty"`
	GeneratedAt string              `json:"generated_at,omitempty"`
	Total       int                 `json:"total"`
	Completed   int                 `json:"completed"`
	Tested      int                 `json:"tested"`
	Reachable   int                 `json:"reachable"`
	Stable      int                 `json:"stable"`
	Countries   []ProbeCountryCount `json:"countries"`
	CurrentNode string              `json:"current_node,omitempty"`
	Error       string              `json:"error,omitempty"`
}

type CountryPortAssignment struct {
	Code      string `json:"code"`
	Name      string `json:"name"`
	Port      int    `json:"port"`
	NodeCount int    `json:"node_count"`
	Enabled   bool   `json:"enabled"`
}

type CountryPortDocument struct {
	UpdatedAt   string                  `json:"updated_at"`
	Assignments []CountryPortAssignment `json:"assignments"`
}

type CountrySummary struct {
	Code         string  `json:"code"`
	Name         string  `json:"name"`
	Total        int     `json:"total"`
	Alive        int     `json:"alive"`
	Dead         int     `json:"dead"`
	AverageMS    int     `json:"average_ms"`
	Availability float64 `json:"availability"`
}

type EgressStatus struct {
	Reachable   bool   `json:"reachable"`
	CountryCode string `json:"country_code"`
	CountryName string `json:"country_name"`
	Colo        string `json:"colo"`
	LatencyMS   int64  `json:"latency_ms"`
	CheckedAt   string `json:"checked_at"`
}

type State struct {
	GeneratedAt          string           `json:"generated_at"`
	StartedAt            string           `json:"started_at"`
	PlatformVersion      string           `json:"platform_version"`
	ControllerReachable  bool             `json:"controller_reachable"`
	ControllerError      string           `json:"controller_error,omitempty"`
	ProviderName         string           `json:"provider_name"`
	ProviderVehicle      string           `json:"provider_vehicle"`
	ProviderUpdatedAt    string           `json:"provider_updated_at"`
	ProviderFileModified string           `json:"provider_file_modified_at"`
	SubscriptionHost     string           `json:"subscription_host"`
	GroupName            string           `json:"group_name"`
	GroupType            string           `json:"group_type"`
	GroupCandidateCount  int              `json:"group_candidate_count"`
	DeclaredNodes        int              `json:"declared_nodes"`
	IdentityCount        int              `json:"identity_count"`
	UniqueServers        int              `json:"unique_servers"`
	UniquePorts          int              `json:"unique_ports"`
	RuntimeNodes         int              `json:"runtime_nodes"`
	Alive                int              `json:"alive"`
	Dead                 int              `json:"dead"`
	Availability         float64          `json:"availability"`
	P50DelayMS           int              `json:"p50_delay_ms"`
	P95DelayMS           int              `json:"p95_delay_ms"`
	LatestHealthAt       string           `json:"latest_health_at"`
	ActiveConnections    int              `json:"active_connections"`
	DownloadTotal        int64            `json:"download_total"`
	UploadTotal          int64            `json:"upload_total"`
	DownloadBPS          float64          `json:"download_bps"`
	UploadBPS            float64          `json:"upload_bps"`
	Egress               EgressStatus     `json:"egress"`
	Countries            []CountrySummary `json:"countries"`
	TaskState            string           `json:"task_state"`
	CloudflareReachable  bool             `json:"cloudflare_reachable"`
	CloudflareHTTPStatus int              `json:"cloudflare_http_status"`
	CloudflareLatencyMS  int64            `json:"cloudflare_latency_ms"`
	Cloudflare           CloudflareHealth `json:"cloudflare"`
	Probe                ProbeStatus      `json:"probe"`
	Nodes                []NodeStatus     `json:"nodes"`
}

type Snapshot struct {
	Time                string  `json:"time"`
	Total               int     `json:"total"`
	Alive               int     `json:"alive"`
	Dead                int     `json:"dead"`
	Availability        float64 `json:"availability"`
	P50DelayMS          int     `json:"p50_delay_ms"`
	P95DelayMS          int     `json:"p95_delay_ms"`
	ActiveConnections   int     `json:"active_connections"`
	DownloadTotal       int64   `json:"download_total"`
	UploadTotal         int64   `json:"upload_total"`
	DownloadBPS         float64 `json:"download_bps"`
	UploadBPS           float64 `json:"upload_bps"`
	EgressCountry       string  `json:"egress_country"`
	CloudflareLatencyMS int64   `json:"cloudflare_latency_ms"`
	ControllerOK        bool    `json:"controller_ok"`
	CloudflareOK        bool    `json:"cloudflare_ok"`
}

type ActionRecord struct {
	Time       string `json:"time"`
	Action     string `json:"action"`
	Success    bool   `json:"success"`
	Message    string `json:"message"`
	RemoteAddr string `json:"remote_addr"`
}

type Monitor struct {
	cfg           Config
	secret        string
	allowedNet    *net.IPNet
	client        *http.Client
	egressClient  *http.Client
	startedAt     time.Time
	mu            sync.RWMutex
	current       State
	refreshMu     sync.Mutex
	actionMu      sync.Mutex
	lastTrafficAt time.Time
	lastDownload  int64
	lastUpload    int64
	lastEgressAt  time.Time
	egress        EgressStatus
	probeSecret   string
	probeClient   *http.Client
	probeRunMu    sync.Mutex
	probeStateMu  sync.RWMutex
	probeState    ProbeStatus
	catalogClient *http.Client
	catalogMu     sync.RWMutex
	catalog       map[string]candidateCacheEntry
	candidateMu   sync.Mutex
	cfOpsToken    string
	cfOpsClient   *http.Client
}

func main() {
	configPath := flag.String("config", "config.json", "path to the monitor configuration")
	flag.Parse()

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	if err := setupLogging(cfg.LogFile); err != nil {
		log.Fatalf("setup logging: %v", err)
	}
	secretBytes, err := readOptionalSecret(cfg.ControllerSecretFile)
	if err != nil {
		log.Fatalf("read controller secret: %v", err)
	}
	_, allowedNet, err := net.ParseCIDR(cfg.AllowedCIDR)
	if err != nil {
		log.Fatalf("parse allowed_cidr: %v", err)
	}
	if err := os.MkdirAll(cfg.HistoryDir, 0o750); err != nil {
		log.Fatalf("create history directory: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(cfg.CandidateStateFile), 0o750); err != nil {
		log.Fatalf("create candidate state directory: %v", err)
	}
	var egressClient *http.Client
	var catalogProxy func(*http.Request) (*url.URL, error) = http.ProxyFromEnvironment
	if cfg.ProxyURL != "" && cfg.EgressTraceURL != "" {
		proxyAddress, err := url.Parse(cfg.ProxyURL)
		if err != nil {
			log.Fatalf("parse proxy_url: %v", err)
		}
		egressClient = &http.Client{
			Timeout: 12 * time.Second,
			Transport: &http.Transport{
				Proxy:               http.ProxyURL(proxyAddress),
				MaxIdleConns:        4,
				MaxIdleConnsPerHost: 2,
				IdleConnTimeout:     30 * time.Second,
			},
		}
		catalogProxy = http.ProxyURL(proxyAddress)
	}
	catalogClient := &http.Client{
		Timeout: 45 * time.Second,
		Transport: &http.Transport{
			Proxy:               catalogProxy,
			MaxIdleConns:        8,
			MaxIdleConnsPerHost: 4,
			IdleConnTimeout:     60 * time.Second,
		},
	}
	var cfOpsToken string
	if cfg.CloudflareOpsURL != "" && cfg.CloudflareOpsTokenFile != "" {
		if tokenBytes, readErr := os.ReadFile(cfg.CloudflareOpsTokenFile); readErr != nil {
			log.Printf("cloudflare operations disabled: read token: %v", readErr)
		} else {
			cfOpsToken = strings.TrimSpace(string(tokenBytes))
		}
	}
	var probeSecret string
	var probeClient *http.Client
	probeConfigured := cfg.ProbeControllerURL != "" && cfg.ProbeSecretFile != "" && cfg.ProbeProviderName != "" && cfg.ProbeGroupName != "" && cfg.ProbeProxyURL != "" && cfg.ProbeTraceURL != "" && cfg.ProbeResultFile != ""
	if probeConfigured {
		probeSecretBytes, readErr := os.ReadFile(cfg.ProbeSecretFile)
		if readErr != nil {
			log.Printf("probe disabled: read controller secret: %v", readErr)
		} else {
			probeSecret = strings.TrimSpace(string(probeSecretBytes))
			probeClient = &http.Client{
				Timeout: 15 * time.Second,
				Transport: &http.Transport{
					Proxy:               nil,
					MaxIdleConns:        4,
					MaxIdleConnsPerHost: 2,
					IdleConnTimeout:     30 * time.Second,
				},
			}
		}
	}

	monitor := &Monitor{
		cfg:        cfg,
		secret:     strings.TrimSpace(string(secretBytes)),
		allowedNet: allowedNet,
		client: &http.Client{
			Timeout: 10 * time.Second,
			Transport: &http.Transport{
				Proxy:               http.ProxyFromEnvironment,
				MaxIdleConns:        16,
				MaxIdleConnsPerHost: 8,
				IdleConnTimeout:     60 * time.Second,
			},
		},
		egressClient: egressClient,
		probeSecret:  probeSecret,
		probeClient:  probeClient,
		startedAt:    time.Now(),
		probeState: ProbeStatus{
			Enabled: probeSecret != "" && probeClient != nil,
		},
		catalogClient: catalogClient,
		catalog:       make(map[string]candidateCacheEntry),
		cfOpsToken:    cfOpsToken,
		cfOpsClient: &http.Client{
			Timeout: 35 * time.Second,
			Transport: &http.Transport{
				Proxy:               catalogProxy,
				MaxIdleConns:        4,
				MaxIdleConnsPerHost: 2,
				IdleConnTimeout:     30 * time.Second,
			},
		},
		current: State{
			StartedAt:       time.Now().Format(time.RFC3339Nano),
			PlatformVersion: platformVersion,
			ProviderName:    cfg.ProviderName,
			GroupName:       cfg.GroupName,
			TaskState:       "Starting",
		},
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	monitor.cleanupHistory()

	mux := http.NewServeMux()
	mux.HandleFunc("/", monitor.handleIndex)
	mux.HandleFunc("/favicon.svg", monitor.handleLogo)
	mux.HandleFunc("/logo.svg", monitor.handleLogo)
	mux.HandleFunc("/healthz", monitor.handleHealthz)
	mux.HandleFunc("/api/status", monitor.handleStatus)
	mux.HandleFunc("/api/history", monitor.handleHistory)
	mux.HandleFunc("/api/actions", monitor.handleActions)
	mux.HandleFunc("/api/action", monitor.handleAction)
	mux.HandleFunc("/api/probe", monitor.handleProbe)
	mux.HandleFunc("/api/speed", monitor.handleSpeedTest)
	mux.HandleFunc("/api/country-ports", monitor.handleCountryPorts)
	mux.HandleFunc("/api/catalog", monitor.handleCatalog)
	mux.HandleFunc("/api/catalog/action", monitor.handleCatalogAction)
	mux.HandleFunc("/api/cloudflare-config", monitor.handleCloudflareConfig)

	server := &http.Server{
		Addr:              cfg.Listen,
		Handler:           securityHeaders(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      90 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		log.Printf("proxy pool monitor %s listening on %s", platformVersion, cfg.Listen)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()
	go func() {
		monitor.refresh()
		monitor.writeSnapshot()
	}()
	go monitor.pollLoop(ctx)
	go monitor.historyLoop(ctx)

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = server.Shutdown(shutdownCtx)
	log.Printf("proxy pool monitor stopped")
}

func loadConfig(path string) (Config, error) {
	absPath, err := filepath.Abs(path)
	if err != nil {
		return Config{}, fmt.Errorf("resolve configuration path: %w", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return Config{}, err
	}
	applyConfigDefaults(&cfg, filepath.Dir(absPath))
	if _, _, err := net.SplitHostPort(cfg.Listen); err != nil {
		return Config{}, fmt.Errorf("invalid listen address %q: %w", cfg.Listen, err)
	}
	controllerURL, err := url.ParseRequestURI(cfg.ControllerURL)
	if err != nil || controllerURL.Host == "" || (controllerURL.Scheme != "http" && controllerURL.Scheme != "https") {
		return Config{}, fmt.Errorf("invalid controller_url %q", cfg.ControllerURL)
	}
	if _, _, err := net.ParseCIDR(cfg.AllowedCIDR); err != nil {
		return Config{}, fmt.Errorf("invalid allowed_cidr %q: %w", cfg.AllowedCIDR, err)
	}
	if cfg.PollSeconds < 5 {
		cfg.PollSeconds = 15
	}
	if cfg.HistorySeconds < 30 {
		cfg.HistorySeconds = 60
	}
	if cfg.EgressSampleSeconds < 60 {
		cfg.EgressSampleSeconds = 300
	}
	if cfg.RetentionDays < 1 || cfg.RetentionDays > 90 {
		cfg.RetentionDays = 30
	}
	if cfg.CountryPortBase < 1024 || cfg.CountryPortBase > 65000 {
		cfg.CountryPortBase = 17901
	}
	return cfg, nil
}

func applyConfigDefaults(cfg *Config, configDir string) {
	if cfg.DataDir == "" {
		cfg.DataDir = filepath.Join(configDir, "var")
	} else {
		cfg.DataDir = resolveConfigPath(configDir, cfg.DataDir)
	}
	defaults := map[*string]string{
		&cfg.Listen:               "127.0.0.1:9191",
		&cfg.ControllerURL:        "http://127.0.0.1:9090",
		&cfg.ControllerSecretFile: filepath.Join(cfg.DataDir, "secrets", "main-controller.secret"),
		&cfg.ProviderName:         "default",
		&cfg.GroupName:            "PROXY",
		&cfg.ProxyURL:             "http://127.0.0.1:7890",
		&cfg.EgressTraceURL:       "https://www.cloudflare.com/cdn-cgi/trace",
		&cfg.ProxyConfigFile:      filepath.Join(cfg.DataDir, "main-pool", "config.yaml"),
		&cfg.ProviderFile:         filepath.Join(cfg.DataDir, "main-pool", "providers", "v2rayn-subscription.yaml"),
		&cfg.HistoryDir:           filepath.Join(cfg.DataDir, "history"),
		&cfg.LogFile:              filepath.Join(cfg.DataDir, "logs", "backend.log"),
		&cfg.ProxyTaskName:        "ProxyTunnel-Main-Pool",
		&cfg.AllowedCIDR:          "127.0.0.0/8",
		&cfg.ProbeTraceURL:        "https://www.cloudflare.com/cdn-cgi/trace",
		&cfg.CountryPortStateFile: filepath.Join(cfg.DataDir, "state", "country-ports.json"),
		&cfg.CandidateStateFile:   filepath.Join(cfg.DataDir, "state", "candidate-selection.json"),
		&cfg.MihomoExecutable:     filepath.Join(configDir, "bin", "mihomo.exe"),
	}
	for destination, value := range defaults {
		if *destination == "" {
			*destination = value
		}
	}
	for _, path := range []*string{
		&cfg.ControllerSecretFile,
		&cfg.ProxyConfigFile,
		&cfg.ProviderFile,
		&cfg.HistoryDir,
		&cfg.LogFile,
		&cfg.ProbeSecretFile,
		&cfg.ProbeResultFile,
		&cfg.ProbeConfigFile,
		&cfg.ProbeProviderFile,
		&cfg.MihomoExecutable,
		&cfg.CountryPortStateFile,
		&cfg.CandidateStateFile,
		&cfg.CloudflareOpsTokenFile,
	} {
		if *path != "" {
			*path = resolveConfigPath(configDir, *path)
		}
	}
}

func resolveConfigPath(configDir, value string) string {
	if value == "" || filepath.IsAbs(value) {
		return filepath.Clean(value)
	}
	return filepath.Clean(filepath.Join(configDir, value))
}

func readOptionalSecret(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		log.Printf("controller secret file %s does not exist; continuing without a controller password", path)
		return nil, nil
	}
	return data, err
}

func setupLogging(path string) error {
	if path == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640)
	if err != nil {
		return err
	}
	log.SetOutput(io.MultiWriter(os.Stdout, file))
	log.SetFlags(log.Ldate | log.Ltime | log.Lmicroseconds)
	return nil
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		next.ServeHTTP(w, r)
	})
}

func (m *Monitor) pollLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Duration(m.cfg.PollSeconds) * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.refresh()
		}
	}
}

func (m *Monitor) historyLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Duration(m.cfg.HistorySeconds) * time.Second)
	cleanupTicker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	defer cleanupTicker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.writeSnapshot()
		case <-cleanupTicker.C:
			m.cleanupHistory()
		}
	}
}

func (m *Monitor) refresh() {
	m.refreshMu.Lock()
	defer m.refreshMu.Unlock()

	m.mu.RLock()
	state := m.current
	state.Nodes = append([]NodeStatus(nil), state.Nodes...)
	m.mu.RUnlock()
	state.GeneratedAt = time.Now().Format(time.RFC3339Nano)
	state.StartedAt = m.startedAt.Format(time.RFC3339Nano)
	state.PlatformVersion = platformVersion
	state.ControllerError = ""
	probeDocument, probeNodes := m.loadProbeDocument()
	state.Probe = m.probeStatusSnapshot(probeDocument)

	providerPath := "/providers/proxies/" + url.PathEscape(m.cfg.ProviderName)
	providerBody, status, err := m.controllerRequest(http.MethodGet, providerPath)
	if err != nil || status < 200 || status >= 300 {
		state.ControllerReachable = false
		if err != nil {
			state.ControllerError = err.Error()
		} else {
			state.ControllerError = fmt.Sprintf("controller returned HTTP %d", status)
		}
	} else {
		var provider ProviderResponse
		if err := json.Unmarshal(providerBody, &provider); err != nil {
			state.ControllerReachable = false
			state.ControllerError = "decode provider response: " + err.Error()
		} else {
			state.ControllerReachable = true
			state.ProviderName = provider.Name
			state.ProviderVehicle = provider.VehicleType
			state.ProviderUpdatedAt = provider.UpdatedAt
			state.RuntimeNodes = len(provider.Proxies)
			state.Nodes, state.Alive, state.Dead, state.P50DelayMS, state.P95DelayMS, state.LatestHealthAt = summarizeNodes(provider.Proxies, probeNodes)
			state.Countries = summarizeCountries(state.Nodes)
			if state.RuntimeNodes > 0 {
				state.Availability = math.Round(float64(state.Alive)/float64(state.RuntimeNodes)*10000) / 100
			} else {
				state.Availability = 0
			}
		}
	}

	if body, httpStatus, err := m.controllerRequest(http.MethodGet, "/connections"); err == nil && httpStatus >= 200 && httpStatus < 300 {
		var connections ConnectionsResponse
		if json.Unmarshal(body, &connections) == nil {
			state.ActiveConnections = len(connections.Connections)
			state.DownloadTotal = connections.DownloadTotal
			state.UploadTotal = connections.UploadTotal
			now := time.Now()
			if !m.lastTrafficAt.IsZero() {
				seconds := now.Sub(m.lastTrafficAt).Seconds()
				if seconds > 0 && connections.DownloadTotal >= m.lastDownload && connections.UploadTotal >= m.lastUpload {
					state.DownloadBPS = float64(connections.DownloadTotal-m.lastDownload) / seconds
					state.UploadBPS = float64(connections.UploadTotal-m.lastUpload) / seconds
				} else {
					state.DownloadBPS, state.UploadBPS = 0, 0
				}
			}
			m.lastTrafficAt = now
			m.lastDownload = connections.DownloadTotal
			m.lastUpload = connections.UploadTotal
		}
	}

	if m.cfg.GroupName != "" {
		if body, httpStatus, err := m.controllerRequest(http.MethodGet, "/proxies/"+url.PathEscape(m.cfg.GroupName)); err == nil && httpStatus >= 200 && httpStatus < 300 {
			var group GroupResponse
			if json.Unmarshal(body, &group) == nil {
				state.GroupName = group.Name
				state.GroupType = group.Type
				state.GroupCandidateCount = len(group.All)
			}
		}
	}

	meta := inspectProviderFiles(m.cfg.ProxyConfigFile, m.cfg.ProviderFile)
	state.SubscriptionHost = meta.SubscriptionHost
	state.DeclaredNodes = meta.DeclaredNodes
	state.IdentityCount = meta.IdentityCount
	state.UniqueServers = meta.UniqueServers
	state.UniquePorts = meta.UniquePorts
	state.ProviderFileModified = meta.ProviderFileModified

	if state.ControllerReachable {
		state.TaskState = "Running"
	} else {
		state.TaskState = "Not responding"
	}
	state.Egress = m.sampleEgressIfDue()

	cfStart := time.Now()
	request, err := http.NewRequest(http.MethodGet, m.cfg.CloudflareHealthURL, nil)
	if err == nil {
		request.Header.Set("User-Agent", "ProxyTunnel-Monitor/"+platformVersion)
		response, requestErr := m.client.Do(request)
		state.CloudflareLatencyMS = time.Since(cfStart).Milliseconds()
		if requestErr == nil {
			state.CloudflareHTTPStatus = response.StatusCode
			limited := io.LimitReader(response.Body, 64*1024)
			data, readErr := io.ReadAll(limited)
			_ = response.Body.Close()
			if readErr == nil && json.Unmarshal(data, &state.Cloudflare) == nil {
				state.CloudflareReachable = response.StatusCode == http.StatusOK && state.Cloudflare.Status == "ok"
				if state.IdentityCount == 0 && state.Cloudflare.IdentityCount > 0 {
					state.IdentityCount = state.Cloudflare.IdentityCount
				}
			} else {
				state.CloudflareReachable = false
			}
		} else {
			state.CloudflareReachable = false
			state.CloudflareHTTPStatus = 0
		}
	}

	m.mu.Lock()
	m.current = state
	m.mu.Unlock()
}

func (m *Monitor) controllerRequest(method, path string) ([]byte, int, error) {
	request, err := http.NewRequest(method, strings.TrimRight(m.cfg.ControllerURL, "/")+path, nil)
	if err != nil {
		return nil, 0, err
	}
	if m.secret != "" {
		request.Header.Set("Authorization", "Bearer "+m.secret)
	}
	request.Header.Set("Accept", "application/json")
	response, err := m.client.Do(request)
	if err != nil {
		return nil, 0, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 4*1024*1024))
	return body, response.StatusCode, err
}

func (m *Monitor) loadProbeDocument() (ProbeDocument, map[string]ProbeNodeResult) {
	document := ProbeDocument{}
	byName := make(map[string]ProbeNodeResult)
	if m.cfg.ProbeResultFile == "" {
		return document, byName
	}
	data, err := os.ReadFile(m.cfg.ProbeResultFile)
	if err != nil {
		return document, byName
	}
	data = bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf})
	if json.Unmarshal(data, &document) != nil {
		return ProbeDocument{}, byName
	}
	for _, node := range document.Nodes {
		if node.Name != "" {
			byName[node.Name] = node
		}
	}
	return document, byName
}

func (m *Monitor) probeStatusSnapshot(document ProbeDocument) ProbeStatus {
	m.probeStateMu.RLock()
	status := m.probeState
	m.probeStateMu.RUnlock()
	status.Enabled = m.probeClient != nil && m.probeSecret != ""
	if document.GeneratedAt != "" {
		status.GeneratedAt = document.GeneratedAt
		status.Total = document.Total
		if !status.Running {
			status.Completed = document.Total
			status.Tested = document.Tested
			status.Reachable = document.Reachable
			status.Stable = document.Stable
			status.Countries = append([]ProbeCountryCount(nil), document.Countries...)
		}
	}
	return status
}

func writeProbeDocument(path string, document ProbeDocument) error {
	if path == "" {
		return errors.New("probe result file is not configured")
	}
	data, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, data, 0o640); err != nil {
		return err
	}
	return replaceFile(temporary, path)
}

func replaceFile(temporary, destination string) error {
	backup := destination + ".swap-backup"
	_ = os.Remove(backup)
	if _, err := os.Stat(destination); err == nil {
		if err := os.Rename(destination, backup); err != nil {
			return err
		}
		if err := os.Rename(temporary, destination); err != nil {
			_ = os.Rename(backup, destination)
			return err
		}
		_ = os.Remove(backup)
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return os.Rename(temporary, destination)
}

func loadCountryPortDocument(path string) CountryPortDocument {
	document := CountryPortDocument{}
	if path == "" {
		return document
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return document
	}
	data = bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf})
	_ = json.Unmarshal(data, &document)
	return document
}

func writeCountryPortDocument(path string, document CountryPortDocument) error {
	if path == "" {
		return errors.New("country port state file is not configured")
	}
	data, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, data, 0o640); err != nil {
		return err
	}
	return replaceFile(temporary, path)
}

func stableNodesByCountry(document ProbeDocument) map[string][]string {
	result := make(map[string][]string)
	for _, node := range document.Nodes {
		code := strings.ToUpper(node.Country)
		if !node.ProviderAlive || !node.Reachable || !node.CountryStable || code == "" || code == "UN" {
			continue
		}
		result[code] = append(result[code], node.Name)
	}
	for code := range result {
		sort.Strings(result[code])
	}
	return result
}

func (m *Monitor) assignCountryPorts(codes []string, stable map[string][]string) ([]CountryPortAssignment, error) {
	previous := loadCountryPortDocument(m.cfg.CountryPortStateFile)
	previousPorts := make(map[string]int)
	usedPorts := make(map[int]bool)
	for _, assignment := range previous.Assignments {
		if assignment.Port >= m.cfg.CountryPortBase && assignment.Port < m.cfg.CountryPortBase+100 {
			previousPorts[strings.ToUpper(assignment.Code)] = assignment.Port
		}
	}
	assignments := make([]CountryPortAssignment, 0, len(codes))
	for _, code := range codes {
		nodes := stable[code]
		if len(nodes) == 0 {
			return nil, fmt.Errorf("country %s has no continuously verified nodes", code)
		}
		port := previousPorts[code]
		if port == 0 || usedPorts[port] {
			for candidate := m.cfg.CountryPortBase; candidate < m.cfg.CountryPortBase+100; candidate++ {
				if !usedPorts[candidate] {
					port = candidate
					break
				}
			}
		}
		if port == 0 {
			return nil, errors.New("no country proxy port is available")
		}
		usedPorts[port] = true
		name := countryCatalog[code]
		if name == "" {
			name = code
		}
		assignments = append(assignments, CountryPortAssignment{Code: code, Name: name, Port: port, NodeCount: len(nodes), Enabled: true})
	}
	sort.Slice(assignments, func(i, j int) bool { return assignments[i].Port < assignments[j].Port })
	return assignments, nil
}

func (m *Monitor) renderProbeConfig(assignments []CountryPortAssignment, stable map[string][]string) ([]byte, error) {
	if m.cfg.ProbeProviderFile == "" {
		return nil, errors.New("probe provider file is not configured")
	}
	providerFile, err := filepath.Rel(filepath.Dir(m.cfg.ProbeConfigFile), m.cfg.ProbeProviderFile)
	if err != nil {
		return nil, fmt.Errorf("resolve probe provider path: %w", err)
	}
	var builder strings.Builder
	builder.WriteString("mixed-port: 17891\n")
	builder.WriteString("allow-lan: false\n")
	builder.WriteString("bind-address: \"127.0.0.1\"\n")
	builder.WriteString("mode: rule\nlog-level: warning\nipv6: false\ntcp-concurrent: true\n")
	builder.WriteString("external-controller: 127.0.0.1:19091\n")
	builder.WriteString("secret: " + strconv.Quote(m.probeSecret) + "\n")
	builder.WriteString("profile:\n  store-selected: false\n  store-fake-ip: false\n")
	if len(assignments) > 0 {
		builder.WriteString("listeners:\n")
		for _, assignment := range assignments {
			builder.WriteString("  - name: " + strconv.Quote("country-"+strings.ToLower(assignment.Code)) + "\n")
			builder.WriteString("    type: http\n")
			builder.WriteString(fmt.Sprintf("    port: %d\n", assignment.Port))
			builder.WriteString("    listen: 0.0.0.0\n")
			builder.WriteString("    proxy: " + strconv.Quote("COUNTRY-"+assignment.Code) + "\n")
			builder.WriteString("    users: []\n")
		}
	}
	builder.WriteString("proxy-providers:\n")
	builder.WriteString("  " + m.cfg.ProbeProviderName + ":\n")
	builder.WriteString("    type: file\n")
	builder.WriteString("    path: " + strconv.Quote(filepath.ToSlash(providerFile)) + "\n")
	builder.WriteString("    health-check:\n      enable: true\n      url: http://cp.cloudflare.com/generate_204\n      interval: 300\n      timeout: 5000\n")
	builder.WriteString("proxy-groups:\n")
	builder.WriteString("  - name: " + strconv.Quote(m.cfg.ProbeGroupName) + "\n    type: select\n    use:\n      - " + m.cfg.ProbeProviderName + "\n")
	for _, assignment := range assignments {
		builder.WriteString("  - name: " + strconv.Quote("COUNTRY-"+assignment.Code) + "\n")
		builder.WriteString("    type: load-balance\n")
		builder.WriteString("    strategy: round-robin\n")
		builder.WriteString("    url: http://cp.cloudflare.com/generate_204\n")
		builder.WriteString("    interval: 300\n    timeout: 5000\n    lazy: false\n")
		builder.WriteString("    use:\n      - " + m.cfg.ProbeProviderName + "\n")
		patterns := make([]string, 0, len(stable[assignment.Code]))
		for _, node := range stable[assignment.Code] {
			patterns = append(patterns, regexp.QuoteMeta(node))
		}
		builder.WriteString("    filter: " + strconv.Quote("^(?:"+strings.Join(patterns, "|")+")$") + "\n")
	}
	builder.WriteString("rules:\n  - MATCH," + m.cfg.ProbeGroupName + "\n")
	return []byte(builder.String()), nil
}

func (m *Monitor) restartProbeTask() error {
	if !regexp.MustCompile(`^[A-Za-z0-9_. -]+$`).MatchString(m.cfg.ProbeTaskName) {
		return errors.New("invalid probe task name")
	}
	task := strings.ReplaceAll(m.cfg.ProbeTaskName, "'", "''")
	command := fmt.Sprintf("$ErrorActionPreference='Stop'; Stop-ScheduledTask -TaskName '%s' -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 700; Start-ScheduledTask -TaskName '%s'", task, task)
	output, err := exec.Command("pwsh.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

func (m *Monitor) waitForProbeController(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_, status, err := m.probeControllerRequest(ctx, http.MethodGet, "/version", nil)
		cancel()
		if err == nil && status >= 200 && status < 300 {
			return nil
		}
		if err != nil {
			lastErr = err
		} else {
			lastErr = fmt.Errorf("controller returned HTTP %d", status)
		}
		time.Sleep(300 * time.Millisecond)
	}
	if lastErr == nil {
		lastErr = errors.New("controller did not become ready")
	}
	return lastErr
}

func (m *Monitor) applyCountryPorts(assignments []CountryPortAssignment, stable map[string][]string) error {
	if m.cfg.ProbeConfigFile == "" || m.cfg.MihomoExecutable == "" || m.cfg.ProbeTaskName == "" {
		return errors.New("country port deployment is not configured")
	}
	config, err := m.renderProbeConfig(assignments, stable)
	if err != nil {
		return err
	}
	configDir := filepath.Dir(m.cfg.ProbeConfigFile)
	temporary := m.cfg.ProbeConfigFile + ".next"
	if err := os.WriteFile(temporary, config, 0o640); err != nil {
		return err
	}
	validationOutput, validationErr := exec.Command(m.cfg.MihomoExecutable, "-t", "-d", configDir, "-f", temporary).CombinedOutput()
	if validationErr != nil {
		return fmt.Errorf("mihomo config validation failed: %w: %s", validationErr, strings.TrimSpace(string(validationOutput)))
	}
	timestamp := time.Now().Format("20060102-150405")
	backup := m.cfg.ProbeConfigFile + ".backup-" + timestamp
	if err := os.Rename(m.cfg.ProbeConfigFile, backup); err != nil {
		return fmt.Errorf("backup current probe config: %w", err)
	}
	if err := os.Rename(temporary, m.cfg.ProbeConfigFile); err != nil {
		_ = os.Rename(backup, m.cfg.ProbeConfigFile)
		return fmt.Errorf("activate new probe config: %w", err)
	}
	if err := m.restartProbeTask(); err != nil {
		failed := m.cfg.ProbeConfigFile + ".failed-" + timestamp
		_ = os.Rename(m.cfg.ProbeConfigFile, failed)
		_ = os.Rename(backup, m.cfg.ProbeConfigFile)
		_ = m.restartProbeTask()
		return fmt.Errorf("restart isolated country proxy: %w", err)
	}
	if err := m.waitForProbeController(15 * time.Second); err != nil {
		failed := m.cfg.ProbeConfigFile + ".failed-" + timestamp
		_ = os.Rename(m.cfg.ProbeConfigFile, failed)
		_ = os.Rename(backup, m.cfg.ProbeConfigFile)
		_ = m.restartProbeTask()
		return fmt.Errorf("verify isolated country proxy: %w", err)
	}
	document := CountryPortDocument{UpdatedAt: time.Now().Format(time.RFC3339Nano), Assignments: assignments}
	if err := writeCountryPortDocument(m.cfg.CountryPortStateFile, document); err != nil {
		failed := m.cfg.ProbeConfigFile + ".failed-" + timestamp
		_ = os.Rename(m.cfg.ProbeConfigFile, failed)
		_ = os.Rename(backup, m.cfg.ProbeConfigFile)
		_ = m.restartProbeTask()
		return fmt.Errorf("write country port state: %w", err)
	}
	return nil
}

func summarizeNodes(proxies []ProviderProxy, probeNodes map[string]ProbeNodeResult) ([]NodeStatus, int, int, int, int, string) {
	nodes := make([]NodeStatus, 0, len(proxies))
	delays := make([]int, 0, len(proxies))
	alive := 0
	latestOverall := time.Time{}
	for _, proxy := range proxies {
		node := NodeStatus{
			Name:          proxy.Name,
			Type:          proxy.Type,
			Alive:         proxy.Alive,
			CountryCode:   "UN",
			CountryName:   countryCatalog["UN"],
			CountrySource: "unverified",
		}
		if probe, ok := probeNodes[proxy.Name]; ok {
			node.EgressReachable = probe.Reachable
			node.EgressIP = probe.EgressIP
			node.EgressColo = strings.ToUpper(probe.Colo)
			node.EgressLatencyMS = probe.LatencyMS
			node.EgressCheckedAt = probe.CheckedAt
			node.EgressProbeError = probe.Error
			node.CountryStable = probe.CountryStable
			node.CountrySamples = probe.StableSamples
			node.DownloadMbps = probe.DownloadMbps
			node.UploadMbps = probe.UploadMbps
			node.SpeedCheckedAt = probe.SpeedCheckedAt
			if probe.Reachable && probe.Country != "" {
				node.CountryCode = strings.ToUpper(probe.Country)
				node.CountryName = countryCatalog[node.CountryCode]
				if node.CountryName == "" {
					node.CountryName = node.CountryCode
				}
				node.CountrySource = "egress_probe"
			}
		}
		var latest time.Time
		for _, history := range proxy.History {
			when := parseTime(history.Time)
			if when.After(latest) {
				latest = when
				node.DelayMS = history.Delay
			}
		}
		if !latest.IsZero() {
			node.LastCheckAt = latest.Format(time.RFC3339Nano)
			if latest.After(latestOverall) {
				latestOverall = latest
			}
		}
		if proxy.Alive {
			alive++
			if node.DelayMS > 0 {
				delays = append(delays, node.DelayMS)
			}
		}
		nodes = append(nodes, node)
	}
	sort.Slice(nodes, func(i, j int) bool {
		if nodes[i].Alive != nodes[j].Alive {
			return nodes[i].Alive
		}
		if nodes[i].DelayMS == 0 || nodes[j].DelayMS == 0 {
			return nodes[i].DelayMS > nodes[j].DelayMS
		}
		return nodes[i].DelayMS < nodes[j].DelayMS
	})
	sort.Ints(delays)
	p50, p95 := percentile(delays, 0.50), percentile(delays, 0.95)
	latestText := ""
	if !latestOverall.IsZero() {
		latestText = latestOverall.Format(time.RFC3339Nano)
	}
	return nodes, alive, len(proxies) - alive, p50, p95, latestText
}

func percentile(values []int, p float64) int {
	if len(values) == 0 {
		return 0
	}
	index := int(math.Ceil(float64(len(values))*p)) - 1
	if index < 0 {
		index = 0
	}
	if index >= len(values) {
		index = len(values) - 1
	}
	return values[index]
}

var countryCatalog = map[string]string{
	"AU": "澳大利亚", "CA": "加拿大", "CN": "中国大陆", "DE": "德国", "FR": "法国",
	"GB": "英国", "HK": "中国香港", "ID": "印度尼西亚", "IN": "印度", "JP": "日本",
	"KR": "韩国", "MY": "马来西亚", "NL": "荷兰", "PH": "菲律宾", "RU": "俄罗斯",
	"SG": "新加坡", "TH": "泰国", "TW": "中国台湾", "US": "美国", "VN": "越南", "UN": "未标注",
}

var countryKeywords = []struct {
	Code     string
	Keywords []string
}{
	{"HK", []string{"🇭🇰", "香港", "hong kong"}},
	{"TW", []string{"🇹🇼", "台湾", "taiwan"}},
	{"JP", []string{"🇯🇵", "日本", "东京", "大阪", "japan", "tokyo", "osaka"}},
	{"SG", []string{"🇸🇬", "新加坡", "singapore"}},
	{"US", []string{"🇺🇸", "美国", "洛杉矶", "西雅图", "纽约", "united states", "los angeles", "seattle"}},
	{"KR", []string{"🇰🇷", "韩国", "首尔", "korea", "seoul"}},
	{"DE", []string{"🇩🇪", "德国", "法兰克福", "germany", "frankfurt"}},
	{"GB", []string{"🇬🇧", "英国", "伦敦", "united kingdom", "london"}},
	{"FR", []string{"🇫🇷", "法国", "巴黎", "france", "paris"}},
	{"CA", []string{"🇨🇦", "加拿大", "canada"}},
	{"AU", []string{"🇦🇺", "澳大利亚", "澳洲", "australia"}},
	{"NL", []string{"🇳🇱", "荷兰", "netherlands", "amsterdam"}},
	{"IN", []string{"🇮🇳", "印度", "india"}},
	{"TH", []string{"🇹🇭", "泰国", "thailand"}},
	{"VN", []string{"🇻🇳", "越南", "vietnam"}},
	{"MY", []string{"🇲🇾", "马来西亚", "malaysia"}},
	{"ID", []string{"🇮🇩", "印度尼西亚", "印尼", "indonesia"}},
	{"PH", []string{"🇵🇭", "菲律宾", "philippines"}},
	{"RU", []string{"🇷🇺", "俄罗斯", "russia"}},
	{"CN", []string{"🇨🇳", "中国大陆", "china mainland"}},
}

func inferCountry(name string) (string, string) {
	lower := strings.ToLower(name)
	for _, entry := range countryKeywords {
		for _, keyword := range entry.Keywords {
			if strings.Contains(lower, strings.ToLower(keyword)) {
				return entry.Code, countryCatalog[entry.Code]
			}
		}
		codePattern := regexp.MustCompile(`(?i)(^|[^a-z])` + entry.Code + `([^a-z]|$)`)
		if codePattern.MatchString(name) {
			return entry.Code, countryCatalog[entry.Code]
		}
	}
	return "UN", countryCatalog["UN"]
}

func summarizeCountries(nodes []NodeStatus) []CountrySummary {
	type aggregate struct {
		CountrySummary
		delayTotal int
		delayCount int
	}
	groups := make(map[string]*aggregate)
	for _, node := range nodes {
		code := node.CountryCode
		if code == "" {
			code = "UN"
		}
		group := groups[code]
		if group == nil {
			group = &aggregate{CountrySummary: CountrySummary{Code: code, Name: countryCatalog[code]}}
			if group.Name == "" {
				group.Name = code
			}
			groups[code] = group
		}
		group.Total++
		if node.Alive {
			group.Alive++
		} else {
			group.Dead++
		}
		if node.DelayMS > 0 {
			group.delayTotal += node.DelayMS
			group.delayCount++
		}
	}
	result := make([]CountrySummary, 0, len(groups))
	for _, group := range groups {
		if group.delayCount > 0 {
			group.AverageMS = int(math.Round(float64(group.delayTotal) / float64(group.delayCount)))
		}
		if group.Total > 0 {
			group.Availability = math.Round(float64(group.Alive)/float64(group.Total)*10000) / 100
		}
		result = append(result, group.CountrySummary)
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Code == "UN" {
			return false
		}
		if result[j].Code == "UN" {
			return true
		}
		if result[i].Alive != result[j].Alive {
			return result[i].Alive > result[j].Alive
		}
		return result[i].Code < result[j].Code
	})
	return result
}

func (m *Monitor) sampleEgressIfDue() EgressStatus {
	if m.egressClient == nil || m.cfg.EgressTraceURL == "" {
		return m.egress
	}
	if !m.lastEgressAt.IsZero() && time.Since(m.lastEgressAt) < time.Duration(m.cfg.EgressSampleSeconds)*time.Second {
		return m.egress
	}
	m.lastEgressAt = time.Now()
	started := time.Now()
	status := EgressStatus{CheckedAt: started.Format(time.RFC3339Nano)}
	request, err := http.NewRequest(http.MethodGet, m.cfg.EgressTraceURL, nil)
	if err != nil {
		m.egress = status
		return status
	}
	request.Header.Set("User-Agent", "ProxyTunnel-Monitor/"+platformVersion)
	response, err := m.egressClient.Do(request)
	status.LatencyMS = time.Since(started).Milliseconds()
	if err != nil {
		m.egress = status
		return status
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 16*1024))
	if err != nil || response.StatusCode < 200 || response.StatusCode >= 300 {
		m.egress = status
		return status
	}
	for _, line := range strings.Split(string(body), "\n") {
		key, value, found := strings.Cut(strings.TrimSpace(line), "=")
		if !found {
			continue
		}
		switch key {
		case "loc":
			status.CountryCode = strings.ToUpper(value)
		case "colo":
			status.Colo = strings.ToUpper(value)
		}
	}
	status.CountryName = countryCatalog[status.CountryCode]
	if status.CountryName == "" && status.CountryCode != "" {
		status.CountryName = status.CountryCode
	}
	status.Reachable = status.CountryCode != ""
	m.egress = status
	return status
}

func (m *Monitor) probeControllerRequest(ctx context.Context, method, path string, body any) ([]byte, int, error) {
	if m.probeClient == nil || m.probeSecret == "" {
		return nil, 0, errors.New("egress probe is not configured")
	}
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, 0, err
		}
		reader = bytes.NewReader(data)
	}
	request, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(m.cfg.ProbeControllerURL, "/")+path, reader)
	if err != nil {
		return nil, 0, err
	}
	request.Header.Set("Authorization", "Bearer "+m.probeSecret)
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json; charset=utf-8")
	}
	response, err := m.probeClient.Do(request)
	if err != nil {
		return nil, 0, err
	}
	defer response.Body.Close()
	responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, 4*1024*1024))
	return responseBody, response.StatusCode, readErr
}

func (m *Monitor) traceSelectedProbeNode(ctx context.Context) (ProbeNodeResult, error) {
	proxyAddress, err := url.Parse(m.cfg.ProbeProxyURL)
	if err != nil {
		return ProbeNodeResult{}, err
	}
	transport := &http.Transport{
		Proxy:             http.ProxyURL(proxyAddress),
		DisableKeepAlives: true,
		IdleConnTimeout:   time.Second,
	}
	client := &http.Client{Timeout: 12 * time.Second, Transport: transport}
	defer transport.CloseIdleConnections()
	started := time.Now()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, m.cfg.ProbeTraceURL, nil)
	if err != nil {
		return ProbeNodeResult{}, err
	}
	request.Header.Set("User-Agent", "ProxyTunnel-Probe/"+platformVersion)
	response, err := client.Do(request)
	latency := time.Since(started).Milliseconds()
	if err != nil {
		return ProbeNodeResult{LatencyMS: latency}, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return ProbeNodeResult{LatencyMS: latency}, fmt.Errorf("trace returned HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 32*1024))
	if err != nil {
		return ProbeNodeResult{LatencyMS: latency}, err
	}
	values := make(map[string]string)
	for _, line := range strings.Split(string(body), "\n") {
		key, value, found := strings.Cut(strings.TrimSpace(line), "=")
		if found {
			values[key] = strings.TrimSpace(value)
		}
	}
	if values["ip"] == "" || values["loc"] == "" {
		return ProbeNodeResult{LatencyMS: latency}, errors.New("trace response does not contain egress identity")
	}
	return ProbeNodeResult{
		Reachable: true,
		Country:   strings.ToUpper(values["loc"]),
		Colo:      strings.ToUpper(values["colo"]),
		EgressIP:  values["ip"],
		LatencyMS: latency,
		CheckedAt: time.Now().Format(time.RFC3339Nano),
	}, nil
}

func (m *Monitor) measureSelectedProbeNode(ctx context.Context) (float64, float64, error) {
	proxyAddress, err := url.Parse(m.cfg.ProbeProxyURL)
	if err != nil {
		return 0, 0, err
	}
	transport := &http.Transport{
		Proxy:             http.ProxyURL(proxyAddress),
		DisableKeepAlives: true,
		IdleConnTimeout:   time.Second,
	}
	client := &http.Client{Timeout: 12 * time.Second, Transport: transport}
	defer transport.CloseIdleConnections()

	measure := func(request *http.Request, expectedBytes int64) (float64, error) {
		request.Header.Set("User-Agent", "ProxyTunnel-Speed/"+platformVersion)
		started := time.Now()
		response, requestErr := client.Do(request)
		if requestErr != nil {
			return 0, requestErr
		}
		defer response.Body.Close()
		if response.StatusCode < 200 || response.StatusCode >= 300 {
			return 0, fmt.Errorf("speed endpoint returned HTTP %d", response.StatusCode)
		}
		transferred, copyErr := io.Copy(io.Discard, io.LimitReader(response.Body, expectedBytes+1024*1024))
		if copyErr != nil {
			return 0, copyErr
		}
		duration := time.Since(started).Seconds()
		if duration <= 0 {
			return 0, errors.New("invalid speed measurement duration")
		}
		if request.Method == http.MethodPost {
			transferred = expectedBytes
		}
		return math.Round((float64(transferred)*8/duration/1_000_000)*100) / 100, nil
	}

	const downloadBytes int64 = 2 * 1024 * 1024
	downloadRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://speed.cloudflare.com/__down?bytes="+strconv.FormatInt(downloadBytes, 10), nil)
	if err != nil {
		return 0, 0, err
	}
	downloadMbps, err := measure(downloadRequest, downloadBytes)
	if err != nil {
		return 0, 0, fmt.Errorf("download measurement: %w", err)
	}

	const uploadBytes int64 = 1024 * 1024
	uploadBody := bytes.NewReader(make([]byte, uploadBytes))
	uploadRequest, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://speed.cloudflare.com/__up", uploadBody)
	if err != nil {
		return 0, 0, err
	}
	uploadRequest.Header.Set("Content-Type", "application/octet-stream")
	uploadMbps, err := measure(uploadRequest, uploadBytes)
	if err != nil {
		return 0, 0, fmt.Errorf("upload measurement: %w", err)
	}
	return downloadMbps, uploadMbps, nil
}

func countryCounts(nodes []ProbeNodeResult) []ProbeCountryCount {
	counts := make(map[string]int)
	for _, node := range nodes {
		if node.Reachable && node.Country != "" {
			counts[strings.ToUpper(node.Country)]++
		}
	}
	result := make([]ProbeCountryCount, 0, len(counts))
	for code, count := range counts {
		result = append(result, ProbeCountryCount{Code: code, Count: count})
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Count != result[j].Count {
			return result[i].Count > result[j].Count
		}
		return result[i].Code < result[j].Code
	})
	return result
}

func (m *Monitor) updateProbeProgress(update func(*ProbeStatus)) {
	m.probeStateMu.Lock()
	update(&m.probeState)
	m.probeStateMu.Unlock()
}

func (m *Monitor) runEgressProbe(remoteAddr string) {
	defer m.probeRunMu.Unlock()
	started := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
	defer cancel()

	finishWithError := func(err error) {
		m.updateProbeProgress(func(status *ProbeStatus) {
			status.Running = false
			status.FinishedAt = time.Now().Format(time.RFC3339Nano)
			status.CurrentNode = ""
			status.Error = err.Error()
		})
		record := ActionRecord{Time: time.Now().Format(time.RFC3339Nano), Action: "egress_scan", Success: false, Message: err.Error(), RemoteAddr: remoteAddr}
		_ = appendJSONLine(filepath.Join(m.cfg.HistoryDir, "actions-"+time.Now().Format("2006-01-02")+".jsonl"), record)
		log.Printf("egress probe failed: %v", err)
	}

	groupPath := "/proxies/" + url.PathEscape(m.cfg.ProbeGroupName)
	providerPath := "/providers/proxies/" + url.PathEscape(m.cfg.ProbeProviderName)
	groupBody, status, err := m.probeControllerRequest(ctx, http.MethodGet, groupPath, nil)
	if err != nil || status < 200 || status >= 300 {
		if err == nil {
			err = fmt.Errorf("probe group returned HTTP %d", status)
		}
		finishWithError(err)
		return
	}
	var group GroupResponse
	if err := json.Unmarshal(groupBody, &group); err != nil {
		finishWithError(fmt.Errorf("decode probe group: %w", err))
		return
	}
	providerBody, status, err := m.probeControllerRequest(ctx, http.MethodGet, providerPath, nil)
	if err != nil || status < 200 || status >= 300 {
		if err == nil {
			err = fmt.Errorf("probe provider returned HTTP %d", status)
		}
		finishWithError(err)
		return
	}
	var provider ProviderResponse
	if err := json.Unmarshal(providerBody, &provider); err != nil {
		finishWithError(fmt.Errorf("decode probe provider: %w", err))
		return
	}
	_, previousNodes := m.loadProbeDocument()

	m.updateProbeProgress(func(probe *ProbeStatus) {
		probe.Enabled = true
		probe.Running = true
		probe.StartedAt = started.Format(time.RFC3339Nano)
		probe.FinishedAt = ""
		probe.Total = len(provider.Proxies)
		probe.Completed = 0
		probe.Tested = 0
		probe.Reachable = 0
		probe.Stable = 0
		probe.Countries = nil
		probe.CurrentNode = ""
		probe.Error = ""
	})

	results := make([]ProbeNodeResult, 0, len(provider.Proxies))
	originalNode := group.Now
	defer func() {
		if originalNode == "" {
			return
		}
		restoreCtx, restoreCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer restoreCancel()
		_, restoreStatus, restoreErr := m.probeControllerRequest(restoreCtx, http.MethodPut, groupPath, map[string]string{"name": originalNode})
		if restoreErr != nil || restoreStatus < 200 || restoreStatus >= 300 {
			log.Printf("restore probe selector failed: status=%d error=%v", restoreStatus, restoreErr)
		}
	}()

	for index, proxy := range provider.Proxies {
		result := ProbeNodeResult{
			Name:          proxy.Name,
			ProviderAlive: proxy.Alive,
			CheckedAt:     time.Now().Format(time.RFC3339Nano),
		}
		m.updateProbeProgress(func(probe *ProbeStatus) { probe.CurrentNode = proxy.Name })
		if !proxy.Alive {
			result.Error = "provider health check failed"
		} else {
			m.updateProbeProgress(func(probe *ProbeStatus) { probe.Tested++ })
			_, selectStatus, selectErr := m.probeControllerRequest(ctx, http.MethodPut, groupPath, map[string]string{"name": proxy.Name})
			if selectErr != nil || selectStatus < 200 || selectStatus >= 300 {
				if selectErr != nil {
					result.Error = selectErr.Error()
				} else {
					result.Error = fmt.Sprintf("selector returned HTTP %d", selectStatus)
				}
			} else {
				time.Sleep(180 * time.Millisecond)
				trace, traceErr := m.traceSelectedProbeNode(ctx)
				trace.Name = proxy.Name
				trace.ProviderAlive = true
				if traceErr != nil {
					trace.Error = traceErr.Error()
					if trace.CheckedAt == "" {
						trace.CheckedAt = time.Now().Format(time.RFC3339Nano)
					}
				}
				result = trace
			}
		}
		if previous, ok := previousNodes[result.Name]; ok {
			result.DownloadMbps = previous.DownloadMbps
			result.UploadMbps = previous.UploadMbps
			result.SpeedCheckedAt = previous.SpeedCheckedAt
		}
		results = append(results, result)
		if result.Reachable {
			if previous, ok := previousNodes[result.Name]; ok && previous.Reachable && strings.EqualFold(previous.Country, result.Country) {
				result.CountryStable = true
				previousSamples := previous.StableSamples
				if previousSamples < 1 {
					previousSamples = 1
				}
				result.StableSamples = previousSamples + 1
			} else {
				result.StableSamples = 1
			}
			results[len(results)-1] = result
		}
		completed := index + 1
		m.updateProbeProgress(func(probe *ProbeStatus) {
			probe.Completed = completed
			if result.Reachable {
				probe.Reachable++
			}
			if result.CountryStable {
				probe.Stable++
			}
			probe.Countries = countryCounts(results)
		})
	}

	document := ProbeDocument{
		GeneratedAt: time.Now().Format(time.RFC3339Nano),
		Total:       len(provider.Proxies),
		Tested:      0,
		Reachable:   0,
		Countries:   countryCounts(results),
		Nodes:       results,
	}
	for _, result := range results {
		if result.ProviderAlive {
			document.Tested++
		}
		if result.Reachable {
			document.Reachable++
		}
		if result.CountryStable {
			document.Stable++
		}
	}
	if err := writeProbeDocument(m.cfg.ProbeResultFile, document); err != nil {
		finishWithError(fmt.Errorf("write probe result: %w", err))
		return
	}
	m.updateProbeProgress(func(probe *ProbeStatus) {
		probe.Running = false
		probe.FinishedAt = time.Now().Format(time.RFC3339Nano)
		probe.GeneratedAt = document.GeneratedAt
		probe.Total = document.Total
		probe.Completed = document.Total
		probe.Tested = document.Tested
		probe.Reachable = document.Reachable
		probe.Stable = document.Stable
		probe.Countries = append([]ProbeCountryCount(nil), document.Countries...)
		probe.CurrentNode = ""
		probe.Error = ""
	})
	log.Printf("egress probe completed: total=%d tested=%d reachable=%d duration=%s", document.Total, document.Tested, document.Reachable, time.Since(started).Round(time.Second))
	record := ActionRecord{Time: time.Now().Format(time.RFC3339Nano), Action: "egress_scan", Success: true, Message: fmt.Sprintf("真实出口扫描完成：%d/%d 可达，%d 个连续验证", document.Reachable, document.Total, document.Stable), RemoteAddr: remoteAddr}
	_ = appendJSONLine(filepath.Join(m.cfg.HistoryDir, "actions-"+time.Now().Format("2006-01-02")+".jsonl"), record)
	go m.refresh()
}

func parseTime(value string) time.Time {
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02T15:04:05.9999999-07:00"} {
		if parsed, err := time.Parse(layout, value); err == nil {
			return parsed
		}
	}
	return time.Time{}
}

type providerMeta struct {
	SubscriptionHost     string
	DeclaredNodes        int
	IdentityCount        int
	UniqueServers        int
	UniquePorts          int
	ProviderFileModified string
}

var (
	uuidPattern   = regexp.MustCompile(`(?i)[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}`)
	namePattern   = regexp.MustCompile(`(?m)^\s*-\s+name:\s*.+$`)
	serverPattern = regexp.MustCompile(`(?mi)^\s+server:\s*["']?([^\s"']+)`)
	portPattern   = regexp.MustCompile(`(?mi)^\s+port:\s*(\d+)\s*$`)
	urlPattern    = regexp.MustCompile(`(?mi)^\s*url:\s*["']?([^\s"']+)`)
)

func inspectProviderFiles(configPath, providerPath string) providerMeta {
	meta := providerMeta{}
	if data, err := os.ReadFile(configPath); err == nil {
		if matches := urlPattern.FindSubmatch(data); len(matches) > 1 {
			if parsed, err := url.Parse(string(matches[1])); err == nil {
				meta.SubscriptionHost = parsed.Hostname()
			}
		}
	}
	if data, err := os.ReadFile(providerPath); err == nil {
		meta.DeclaredNodes = len(namePattern.FindAll(data, -1))
		meta.IdentityCount = uniqueMatches(uuidPattern.FindAll(data, -1))
		meta.UniqueServers = uniqueSubmatches(serverPattern.FindAllSubmatch(data, -1))
		meta.UniquePorts = uniqueSubmatches(portPattern.FindAllSubmatch(data, -1))
		if stat, statErr := os.Stat(providerPath); statErr == nil {
			meta.ProviderFileModified = stat.ModTime().Format(time.RFC3339Nano)
		}
	}
	return meta
}

func uniqueMatches(matches [][]byte) int {
	values := make(map[string]struct{}, len(matches))
	for _, match := range matches {
		values[strings.ToLower(string(match))] = struct{}{}
	}
	return len(values)
}

func uniqueSubmatches(matches [][][]byte) int {
	values := make(map[string]struct{}, len(matches))
	for _, match := range matches {
		if len(match) > 1 {
			values[strings.ToLower(string(match[1]))] = struct{}{}
		}
	}
	return len(values)
}

func (m *Monitor) writeSnapshot() {
	m.mu.RLock()
	state := m.current
	m.mu.RUnlock()
	if state.GeneratedAt == "" {
		return
	}
	snapshot := Snapshot{
		Time:                time.Now().Format(time.RFC3339Nano),
		Total:               state.RuntimeNodes,
		Alive:               state.Alive,
		Dead:                state.Dead,
		Availability:        state.Availability,
		P50DelayMS:          state.P50DelayMS,
		P95DelayMS:          state.P95DelayMS,
		ActiveConnections:   state.ActiveConnections,
		DownloadTotal:       state.DownloadTotal,
		UploadTotal:         state.UploadTotal,
		DownloadBPS:         state.DownloadBPS,
		UploadBPS:           state.UploadBPS,
		EgressCountry:       state.Egress.CountryCode,
		CloudflareLatencyMS: state.CloudflareLatencyMS,
		ControllerOK:        state.ControllerReachable,
		CloudflareOK:        state.CloudflareReachable,
	}
	path := filepath.Join(m.cfg.HistoryDir, "metrics-"+time.Now().Format("2006-01-02")+".jsonl")
	if err := appendJSONLine(path, snapshot); err != nil {
		log.Printf("write snapshot: %v", err)
	}
}

func appendJSONLine(path string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = file.Write(append(data, '\n'))
	return err
}

func (m *Monitor) cleanupHistory() {
	cutoff := time.Now().AddDate(0, 0, -m.cfg.RetentionDays)
	entries, err := os.ReadDir(m.cfg.HistoryDir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".jsonl") {
			continue
		}
		info, err := entry.Info()
		if err == nil && info.ModTime().Before(cutoff) {
			if removeErr := os.Remove(filepath.Join(m.cfg.HistoryDir, entry.Name())); removeErr != nil {
				log.Printf("remove expired history %s: %v", entry.Name(), removeErr)
			}
		}
	}
}

func (m *Monitor) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	data, err := staticFiles.ReadFile("web/index.html")
	if err != nil {
		http.Error(w, "UI unavailable", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write(data)
}

func (m *Monitor) handleLogo(w http.ResponseWriter, r *http.Request) {
	data, err := staticFiles.ReadFile("web/logo.svg")
	if err != nil {
		http.Error(w, "logo unavailable", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "image/svg+xml")
	w.Header().Set("Cache-Control", "public, max-age=86400")
	_, _ = w.Write(data)
}

func (m *Monitor) handleHealthz(w http.ResponseWriter, r *http.Request) {
	m.mu.RLock()
	state := m.current
	m.mu.RUnlock()
	status := http.StatusOK
	if !state.ControllerReachable {
		status = http.StatusServiceUnavailable
	}
	writeJSON(w, status, map[string]any{
		"status":               map[bool]string{true: "ok", false: "degraded"}[state.ControllerReachable],
		"controller_reachable": state.ControllerReachable,
		"cloudflare_reachable": state.CloudflareReachable,
		"generated_at":         state.GeneratedAt,
		"version":              platformVersion,
	})
}

func (m *Monitor) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	m.mu.RLock()
	state := m.current
	state.Nodes = append([]NodeStatus(nil), state.Nodes...)
	m.mu.RUnlock()
	writeJSON(w, http.StatusOK, state)
}

func (m *Monitor) handleProbe(w http.ResponseWriter, r *http.Request) {
	document, _ := m.loadProbeDocument()
	if r.Method == http.MethodGet {
		writeJSON(w, http.StatusOK, m.probeStatusSnapshot(document))
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodGet+", "+http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !m.isAllowedRemote(r.RemoteAddr) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	if r.Header.Get("X-ProxyTunnel-Action") != "confirmed" || !sameOrigin(r) {
		http.Error(w, "confirmation required", http.StatusForbidden)
		return
	}
	if m.probeClient == nil || m.probeSecret == "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "egress probe is not configured"})
		return
	}
	if !m.probeRunMu.TryLock() {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "an egress probe is already running"})
		return
	}
	m.updateProbeProgress(func(probe *ProbeStatus) {
		probe.Enabled = true
		probe.Running = true
		probe.StartedAt = time.Now().Format(time.RFC3339Nano)
		probe.FinishedAt = ""
		probe.Completed = 0
		probe.CurrentNode = ""
		probe.Error = ""
	})
	go m.runEgressProbe(remoteIP(r.RemoteAddr))
	writeJSON(w, http.StatusAccepted, map[string]any{"success": true, "message": "egress probe started"})
}

func (m *Monitor) handleSpeedTest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !m.isAllowedRemote(r.RemoteAddr) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	if r.Header.Get("X-ProxyTunnel-Action") != "confirmed" || !sameOrigin(r) {
		http.Error(w, "confirmation required", http.StatusForbidden)
		return
	}
	if m.probeClient == nil || m.probeSecret == "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "egress probe is not configured"})
		return
	}
	var payload struct {
		Node string `json:"node"`
	}
	decoder := json.NewDecoder(io.LimitReader(r.Body, 16*1024))
	if err := decoder.Decode(&payload); err != nil || strings.TrimSpace(payload.Node) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "a node name is required"})
		return
	}
	if !m.probeRunMu.TryLock() {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "an egress probe or speed test is already running"})
		return
	}
	defer m.probeRunMu.Unlock()

	document, documentNodes := m.loadProbeDocument()
	currentResult, exists := documentNodes[payload.Node]
	if !exists || !currentResult.Reachable {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "run a successful egress probe for this node first"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 35*time.Second)
	defer cancel()
	groupPath := "/proxies/" + url.PathEscape(m.cfg.ProbeGroupName)
	providerPath := "/providers/proxies/" + url.PathEscape(m.cfg.ProbeProviderName)
	providerBody, providerStatus, err := m.probeControllerRequest(ctx, http.MethodGet, providerPath, nil)
	if err != nil || providerStatus < 200 || providerStatus >= 300 {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "unable to read the probe provider"})
		return
	}
	var provider ProviderResponse
	if json.Unmarshal(providerBody, &provider) != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "unable to decode the probe provider"})
		return
	}
	validNode := false
	for _, candidate := range provider.Proxies {
		if candidate.Name == payload.Node && candidate.Alive {
			validNode = true
			break
		}
	}
	if !validNode {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "the selected node is not currently healthy"})
		return
	}

	groupBody, groupStatus, err := m.probeControllerRequest(ctx, http.MethodGet, groupPath, nil)
	if err != nil || groupStatus < 200 || groupStatus >= 300 {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "unable to read the probe selector"})
		return
	}
	var group GroupResponse
	if json.Unmarshal(groupBody, &group) != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "unable to decode the probe selector"})
		return
	}
	if group.Now != "" {
		defer func(original string) {
			restoreCtx, restoreCancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer restoreCancel()
			_, _, _ = m.probeControllerRequest(restoreCtx, http.MethodPut, groupPath, map[string]string{"name": original})
		}(group.Now)
	}
	_, selectStatus, err := m.probeControllerRequest(ctx, http.MethodPut, groupPath, map[string]string{"name": payload.Node})
	if err != nil || selectStatus < 200 || selectStatus >= 300 {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "unable to select the node for testing"})
		return
	}
	time.Sleep(180 * time.Millisecond)
	downloadMbps, uploadMbps, err := m.measureSelectedProbeNode(ctx)
	if err != nil {
		record := ActionRecord{Time: time.Now().Format(time.RFC3339Nano), Action: "speed_test", Success: false, Message: err.Error(), RemoteAddr: remoteIP(r.RemoteAddr)}
		_ = appendJSONLine(filepath.Join(m.cfg.HistoryDir, "actions-"+time.Now().Format("2006-01-02")+".jsonl"), record)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	checkedAt := time.Now().Format(time.RFC3339Nano)
	for index := range document.Nodes {
		if document.Nodes[index].Name == payload.Node {
			document.Nodes[index].DownloadMbps = downloadMbps
			document.Nodes[index].UploadMbps = uploadMbps
			document.Nodes[index].SpeedCheckedAt = checkedAt
			break
		}
	}
	if err := writeProbeDocument(m.cfg.ProbeResultFile, document); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to save speed result"})
		return
	}
	record := ActionRecord{Time: checkedAt, Action: "speed_test", Success: true, Message: fmt.Sprintf("节点测速完成：下行 %.2f Mbps，上行 %.2f Mbps", downloadMbps, uploadMbps), RemoteAddr: remoteIP(r.RemoteAddr)}
	_ = appendJSONLine(filepath.Join(m.cfg.HistoryDir, "actions-"+time.Now().Format("2006-01-02")+".jsonl"), record)
	go m.refresh()
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": record.Message, "download_mbps": downloadMbps, "upload_mbps": uploadMbps, "checked_at": checkedAt})
}

func (m *Monitor) countryPortSnapshot(stable map[string][]string) map[string]any {
	available := make([]CountryPortAssignment, 0, len(stable))
	for code, nodes := range stable {
		name := countryCatalog[code]
		if name == "" {
			name = code
		}
		available = append(available, CountryPortAssignment{Code: code, Name: name, NodeCount: len(nodes)})
	}
	sort.Slice(available, func(i, j int) bool {
		if available[i].NodeCount == available[j].NodeCount {
			return available[i].Code < available[j].Code
		}
		return available[i].NodeCount > available[j].NodeCount
	})
	document := loadCountryPortDocument(m.cfg.CountryPortStateFile)
	for index := range document.Assignments {
		document.Assignments[index].NodeCount = len(stable[strings.ToUpper(document.Assignments[index].Code)])
	}
	configured := m.cfg.ProbeConfigFile != "" && m.cfg.ProbeProviderFile != "" && m.cfg.ProbeTaskName != "" && m.cfg.MihomoExecutable != "" && m.cfg.CountryPortStateFile != "" && m.probeSecret != ""
	return map[string]any{
		"configured":  configured,
		"port_base":   m.cfg.CountryPortBase,
		"updated_at":  document.UpdatedAt,
		"available":   available,
		"assignments": document.Assignments,
	}
}

func (m *Monitor) handleCountryPorts(w http.ResponseWriter, r *http.Request) {
	probeDocument, _ := m.loadProbeDocument()
	stable := stableNodesByCountry(probeDocument)
	if r.Method == http.MethodGet {
		writeJSON(w, http.StatusOK, m.countryPortSnapshot(stable))
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodGet+", "+http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !m.isAllowedRemote(r.RemoteAddr) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	if r.Header.Get("X-ProxyTunnel-Action") != "confirmed" || !sameOrigin(r) {
		http.Error(w, "confirmation required", http.StatusForbidden)
		return
	}
	if m.cfg.ProbeConfigFile == "" || m.cfg.ProbeProviderFile == "" || m.cfg.ProbeTaskName == "" || m.cfg.MihomoExecutable == "" || m.cfg.CountryPortStateFile == "" || m.probeSecret == "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "country proxy ports are not configured"})
		return
	}
	var payload struct {
		Countries []string `json:"countries"`
	}
	decoder := json.NewDecoder(io.LimitReader(r.Body, 16*1024))
	if err := decoder.Decode(&payload); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request"})
		return
	}
	if len(payload.Countries) > 20 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "too many countries were selected"})
		return
	}
	unique := make(map[string]bool, len(payload.Countries))
	codes := make([]string, 0, len(payload.Countries))
	for _, rawCode := range payload.Countries {
		code := strings.ToUpper(strings.TrimSpace(rawCode))
		if !regexp.MustCompile(`^[A-Z]{2}$`).MatchString(code) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid country code"})
			return
		}
		if !unique[code] {
			unique[code] = true
			codes = append(codes, code)
		}
	}
	sort.Strings(codes)
	if !m.probeRunMu.TryLock() {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "an egress probe, speed test, or country port update is already running"})
		return
	}
	defer m.probeRunMu.Unlock()

	assignments, err := m.assignCountryPorts(codes, stable)
	if err == nil {
		err = m.applyCountryPorts(assignments, stable)
	}
	message := "国家专用代理端口已更新"
	if len(assignments) == 0 && err == nil {
		message = "国家专用代理端口已全部关闭"
	}
	if err != nil {
		message = err.Error()
	}
	record := ActionRecord{Time: time.Now().Format(time.RFC3339Nano), Action: "country_ports", Success: err == nil, Message: message, RemoteAddr: remoteIP(r.RemoteAddr)}
	_ = appendJSONLine(filepath.Join(m.cfg.HistoryDir, "actions-"+time.Now().Format("2006-01-02")+".jsonl"), record)
	if err != nil {
		log.Printf("country proxy port update failed: %v", err)
		writeJSON(w, http.StatusBadGateway, map[string]any{"success": false, "message": message})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": message, "state": m.countryPortSnapshot(stable)})
}

func (m *Monitor) handleHistory(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	duration := 24 * time.Hour
	switch r.URL.Query().Get("range") {
	case "7d":
		duration = 7 * 24 * time.Hour
	case "30d":
		duration = 30 * 24 * time.Hour
	}
	items, err := m.readSnapshots(time.Now().Add(-duration))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"points": downsample(items, 720), "retention_days": m.cfg.RetentionDays})
}

func (m *Monitor) readSnapshots(cutoff time.Time) ([]Snapshot, error) {
	paths, err := filepath.Glob(filepath.Join(m.cfg.HistoryDir, "metrics-*.jsonl"))
	if err != nil {
		return nil, err
	}
	items := make([]Snapshot, 0, 1024)
	for _, path := range paths {
		file, err := os.Open(path)
		if err != nil {
			continue
		}
		scanner := bufio.NewScanner(file)
		scanner.Buffer(make([]byte, 64*1024), 1024*1024)
		for scanner.Scan() {
			var item Snapshot
			if json.Unmarshal(scanner.Bytes(), &item) != nil {
				continue
			}
			when := parseTime(item.Time)
			if !when.IsZero() && !when.Before(cutoff) {
				items = append(items, item)
			}
		}
		_ = file.Close()
	}
	sort.Slice(items, func(i, j int) bool { return items[i].Time < items[j].Time })
	return items, nil
}

func downsample(items []Snapshot, max int) []Snapshot {
	if len(items) <= max || max < 2 {
		return items
	}
	step := int(math.Ceil(float64(len(items)) / float64(max)))
	result := make([]Snapshot, 0, max+1)
	for i := 0; i < len(items); i += step {
		end := i + step
		if end > len(items) {
			end = len(items)
		}
		result = append(result, items[end-1])
	}
	if result[len(result)-1].Time != items[len(items)-1].Time {
		result = append(result, items[len(items)-1])
	}
	return result
}

func (m *Monitor) handleActions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	limit := 30
	if value, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && value > 0 && value <= 100 {
		limit = value
	}
	items := m.readActionRecords(limit)
	writeJSON(w, http.StatusOK, map[string]any{"actions": items})
}

func (m *Monitor) readActionRecords(limit int) []ActionRecord {
	paths, _ := filepath.Glob(filepath.Join(m.cfg.HistoryDir, "actions-*.jsonl"))
	sort.Sort(sort.Reverse(sort.StringSlice(paths)))
	items := make([]ActionRecord, 0, limit)
	for _, path := range paths {
		file, err := os.Open(path)
		if err != nil {
			continue
		}
		fileItems := make([]ActionRecord, 0, 16)
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			var item ActionRecord
			if json.Unmarshal(scanner.Bytes(), &item) == nil {
				fileItems = append(fileItems, item)
			}
		}
		_ = file.Close()
		for i := len(fileItems) - 1; i >= 0 && len(items) < limit; i-- {
			items = append(items, fileItems[i])
		}
		if len(items) >= limit {
			break
		}
	}
	return items
}

func (m *Monitor) handleAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !m.isAllowedRemote(r.RemoteAddr) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	if r.Header.Get("X-ProxyTunnel-Action") != "confirmed" || !sameOrigin(r) {
		http.Error(w, "confirmation required", http.StatusForbidden)
		return
	}
	if !m.actionMu.TryLock() {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "another management action is running"})
		return
	}
	defer m.actionMu.Unlock()

	var payload struct {
		Action string `json:"action"`
	}
	decoder := json.NewDecoder(io.LimitReader(r.Body, 1024))
	if err := decoder.Decode(&payload); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request"})
		return
	}
	message, err := m.runAction(payload.Action)
	record := ActionRecord{
		Time:       time.Now().Format(time.RFC3339Nano),
		Action:     payload.Action,
		Success:    err == nil,
		Message:    message,
		RemoteAddr: remoteIP(r.RemoteAddr),
	}
	path := filepath.Join(m.cfg.HistoryDir, "actions-"+time.Now().Format("2006-01-02")+".jsonl")
	if appendErr := appendJSONLine(path, record); appendErr != nil {
		log.Printf("write action record: %v", appendErr)
	}
	if err != nil {
		log.Printf("management action %s failed: %v", payload.Action, err)
		writeJSON(w, http.StatusBadGateway, map[string]any{"success": false, "message": message})
		return
	}
	log.Printf("management action %s succeeded from %s", payload.Action, record.RemoteAddr)
	if payload.Action != "restart" {
		m.refresh()
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": message})
}

func (m *Monitor) runAction(action string) (string, error) {
	providerPath := "/providers/proxies/" + url.PathEscape(m.cfg.ProviderName)
	switch action {
	case "healthcheck":
		_, status, err := m.controllerRequest(http.MethodGet, providerPath+"/healthcheck")
		if err != nil {
			return "健康检查触发失败", err
		}
		if status < 200 || status >= 300 {
			return "健康检查触发失败", fmt.Errorf("controller returned HTTP %d", status)
		}
		return "已触发全部节点健康检查", nil
	case "refresh":
		_, status, err := m.controllerRequest(http.MethodPut, providerPath)
		if err != nil {
			return "订阅刷新失败", err
		}
		if status < 200 || status >= 300 {
			return "订阅刷新失败", fmt.Errorf("controller returned HTTP %d", status)
		}
		return "订阅已刷新，节点状态将在下一轮更新", nil
	case "restart":
		if !regexp.MustCompile(`^[A-Za-z0-9_. -]+$`).MatchString(m.cfg.ProxyTaskName) {
			return "代理服务重启失败", errors.New("invalid task name")
		}
		task := strings.ReplaceAll(m.cfg.ProxyTaskName, "'", "''")
		command := fmt.Sprintf("$ErrorActionPreference='Stop'; Stop-ScheduledTask -TaskName '%s' -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2; Start-ScheduledTask -TaskName '%s'", task, task)
		output, err := exec.Command("pwsh.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command).CombinedOutput()
		if err != nil {
			return "代理服务重启失败", fmt.Errorf("%w: %s", err, strings.TrimSpace(string(output)))
		}
		return "代理服务重启命令已执行", nil
	default:
		return "不支持的操作", errors.New("unsupported action")
	}
}

func (m *Monitor) isAllowedRemote(remote string) bool {
	ip := net.ParseIP(remoteIP(remote))
	return ip != nil && (ip.IsLoopback() || m.allowedNet.Contains(ip))
}

func remoteIP(remote string) string {
	host, _, err := net.SplitHostPort(remote)
	if err == nil {
		return host
	}
	return remote
}

func sameOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	parsed, err := url.Parse(origin)
	return err == nil && strings.EqualFold(parsed.Host, r.Host)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
