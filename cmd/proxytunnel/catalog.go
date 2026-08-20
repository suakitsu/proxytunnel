package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

const candidateCacheTTL = 15 * time.Minute

type candidateSourceDefinition struct {
	ID          string
	Name        string
	Description string
	URL         string
}

var candidateSources = []candidateSourceDefinition{
	{ID: "proxyip", Name: "ProxyIP", Description: "Cloudflare 反代候选；官方后台最多选择 8 个", URL: "https://zip.cm.edu.kg.cmliussss.net/all.json"},
	{ID: "socks5", Name: "SOCKS5", Description: "公共 SOCKS5 反代候选", URL: "https://raw.githubusercontent.com/EDT-Pages/Proxy-List/main/data/socks5.json"},
	{ID: "http", Name: "HTTP", Description: "公共 HTTP 反代候选", URL: "https://raw.githubusercontent.com/EDT-Pages/Proxy-List/main/data/http.json"},
	{ID: "https", Name: "HTTPS", Description: "公共 HTTPS 反代候选", URL: "https://raw.githubusercontent.com/EDT-Pages/Proxy-List/main/data/https.json"},
}

type CandidateVerification struct {
	Success        bool   `json:"success"`
	CheckedAt      string `json:"checked_at"`
	LatencyMS      int64  `json:"latency_ms"`
	EgressIP       string `json:"egress_ip,omitempty"`
	CountryCode    string `json:"country_code,omitempty"`
	CountryName    string `json:"country_name,omitempty"`
	Colo           string `json:"colo,omitempty"`
	CountryMatched bool   `json:"country_matched"`
	Error          string `json:"error,omitempty"`
}

type CandidateNode struct {
	ID              string                 `json:"id"`
	Source          string                 `json:"source"`
	Protocol        string                 `json:"protocol"`
	Address         string                 `json:"address"`
	IP              string                 `json:"ip"`
	Port            int                    `json:"port"`
	CountryCode     string                 `json:"country_code"`
	CountryName     string                 `json:"country_name"`
	CountryEmoji    string                 `json:"country_emoji,omitempty"`
	City            string                 `json:"city,omitempty"`
	ASN             string                 `json:"asn,omitempty"`
	Organization    string                 `json:"organization,omitempty"`
	Continent       string                 `json:"continent,omitempty"`
	Selected        bool                   `json:"selected"`
	Verification    *CandidateVerification `json:"verification,omitempty"`
	CountryEvidence string                 `json:"country_evidence"`
}

type candidateCacheEntry struct {
	Nodes       []CandidateNode
	RefreshedAt time.Time
	Error       string
}

type CandidateStateEntry struct {
	Node         CandidateNode         `json:"node"`
	Selected     bool                  `json:"selected"`
	Verification CandidateVerification `json:"verification"`
}

type CandidateStateDocument struct {
	UpdatedAt string                         `json:"updated_at"`
	Entries   map[string]CandidateStateEntry `json:"entries"`
}

type candidateSourceSummary struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Total       int    `json:"total"`
	Countries   int    `json:"countries"`
	RefreshedAt string `json:"refreshed_at,omitempty"`
	Error       string `json:"error,omitempty"`
}

type candidateCountrySummary struct {
	Code     string `json:"code"`
	Name     string `json:"name"`
	Emoji    string `json:"emoji,omitempty"`
	Total    int    `json:"total"`
	Verified int    `json:"verified"`
	Selected int    `json:"selected"`
}

func candidateSource(id string) (candidateSourceDefinition, bool) {
	for _, source := range candidateSources {
		if source.ID == id {
			return source, true
		}
	}
	return candidateSourceDefinition{}, false
}

func candidateID(source, address string) string {
	sum := sha256.Sum256([]byte(source + "\x00" + strings.ToLower(strings.TrimSpace(address))))
	return source + "-" + hex.EncodeToString(sum[:8])
}

func (m *Monitor) loadCatalogSource(ctx context.Context, sourceID string, force bool) (candidateCacheEntry, error) {
	source, ok := candidateSource(sourceID)
	if !ok {
		return candidateCacheEntry{}, errors.New("unknown candidate source")
	}
	m.catalogMu.RLock()
	cached, exists := m.catalog[sourceID]
	m.catalogMu.RUnlock()
	if exists && !force && time.Since(cached.RefreshedAt) < candidateCacheTTL {
		return cached, nil
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, source.URL, nil)
	if err != nil {
		return cached, err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", "ProxyTunnel-Catalog/0.1")
	response, err := m.catalogClient.Do(request)
	if err != nil {
		if exists {
			cached.Error = err.Error()
			return cached, nil
		}
		return candidateCacheEntry{}, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		err = fmt.Errorf("candidate source returned HTTP %d", response.StatusCode)
		if exists {
			cached.Error = err.Error()
			return cached, nil
		}
		return candidateCacheEntry{}, err
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 32<<20))
	if err != nil {
		return cached, err
	}
	nodes, err := parseCandidateSource(sourceID, data)
	if err != nil {
		return cached, err
	}
	entry := candidateCacheEntry{Nodes: nodes, RefreshedAt: time.Now()}
	m.catalogMu.Lock()
	m.catalog[sourceID] = entry
	m.catalogMu.Unlock()
	return entry, nil
}

func parseCandidateSource(sourceID string, data []byte) ([]CandidateNode, error) {
	if sourceID == "proxyip" {
		var document struct {
			Data []struct {
				IP   string `json:"ip"`
				Port []int  `json:"port"`
				Meta struct {
					Country      string `json:"country"`
					CountryCN    string `json:"country_cn"`
					CountryEmoji string `json:"country_emoji"`
					City         string `json:"city"`
					ASN          any    `json:"asn"`
					Organization string `json:"asOrganization"`
					Continent    string `json:"continent"`
				} `json:"meta"`
			} `json:"data"`
		}
		if err := json.Unmarshal(data, &document); err != nil {
			return nil, err
		}
		nodes := make([]CandidateNode, 0, len(document.Data))
		for _, item := range document.Data {
			if net.ParseIP(item.IP) == nil || !containsInt(item.Port, 443) {
				continue
			}
			address := strings.TrimSpace(item.IP)
			nodes = append(nodes, CandidateNode{
				ID: candidateID(sourceID, address), Source: sourceID, Protocol: "proxyip", Address: address,
				IP: address, Port: 443, CountryCode: strings.ToUpper(item.Meta.Country),
				CountryName: item.Meta.CountryCN, CountryEmoji: item.Meta.CountryEmoji, City: item.Meta.City,
				ASN: fmt.Sprint(item.Meta.ASN), Organization: item.Meta.Organization, Continent: item.Meta.Continent,
				CountryEvidence: "来源标注，选用前需实测",
			})
		}
		return nodes, nil
	}

	var raw []struct {
		Proxy        string `json:"proxy"`
		Protocol     string `json:"protocol"`
		IP           string `json:"ip"`
		Port         int    `json:"port"`
		Country      string `json:"country"`
		CountryCN    string `json:"country_cn"`
		CountryEmoji string `json:"country_emoji"`
		City         string `json:"city"`
		ASN          any    `json:"asn"`
		Organization string `json:"asOrganization"`
		Continent    string `json:"continent"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	nodes := make([]CandidateNode, 0, len(raw))
	for _, item := range raw {
		address := strings.TrimSpace(item.Proxy)
		protocol := strings.ToLower(strings.TrimSpace(item.Protocol))
		if address == "" || net.ParseIP(item.IP) == nil || item.Port < 1 || item.Port > 65535 {
			continue
		}
		if protocol == "" {
			protocol = sourceID
		}
		nodes = append(nodes, CandidateNode{
			ID: candidateID(sourceID, address), Source: sourceID, Protocol: protocol, Address: address,
			IP: item.IP, Port: item.Port, CountryCode: strings.ToUpper(item.Country), CountryName: item.CountryCN,
			CountryEmoji: item.CountryEmoji, City: item.City, ASN: fmt.Sprint(item.ASN),
			Organization: item.Organization, Continent: item.Continent, CountryEvidence: "来源标注，选用前需实测",
		})
	}
	return nodes, nil
}

func containsInt(values []int, expected int) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}

func loadCandidateState(path string) CandidateStateDocument {
	document := CandidateStateDocument{Entries: make(map[string]CandidateStateEntry)}
	data, err := os.ReadFile(path)
	if err == nil {
		_ = json.Unmarshal(data, &document)
	}
	if document.Entries == nil {
		document.Entries = make(map[string]CandidateStateEntry)
	}
	return document
}

func writeCandidateState(path string, document CandidateStateDocument) error {
	document.UpdatedAt = time.Now().Format(time.RFC3339Nano)
	data, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, data, 0o640); err != nil {
		return err
	}
	return replaceFile(temporary, path)
}

func mergeCandidateState(nodes []CandidateNode, state CandidateStateDocument) {
	for index := range nodes {
		if entry, ok := state.Entries[nodes[index].ID]; ok {
			nodes[index].Selected = entry.Selected
			verification := entry.Verification
			nodes[index].Verification = &verification
			if verification.Success && verification.CountryCode != "" {
				nodes[index].CountryEvidence = "已从 65 服务器实测出口"
			}
		}
	}
}

func (m *Monitor) handleCatalog(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	sourceFilter := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("source")))
	if sourceFilter == "" {
		sourceFilter = "all"
	}
	if sourceFilter != "all" {
		if _, ok := candidateSource(sourceFilter); !ok {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unknown candidate source"})
			return
		}
	}

	type result struct {
		id    string
		entry candidateCacheEntry
		err   error
	}
	results := make(chan result, len(candidateSources))
	ctx, cancel := context.WithTimeout(r.Context(), 55*time.Second)
	defer cancel()
	for _, definition := range candidateSources {
		definition := definition
		go func() {
			entry, err := m.loadCatalogSource(ctx, definition.ID, false)
			results <- result{id: definition.ID, entry: entry, err: err}
		}()
	}
	entries := make(map[string]candidateCacheEntry, len(candidateSources))
	for range candidateSources {
		item := <-results
		if item.err != nil {
			item.entry.Error = item.err.Error()
		}
		entries[item.id] = item.entry
	}

	m.candidateMu.Lock()
	state := loadCandidateState(m.cfg.CandidateStateFile)
	m.candidateMu.Unlock()
	allNodes := make([]CandidateNode, 0, 4096)
	for _, definition := range candidateSources {
		entry := entries[definition.ID]
		nodes := append([]CandidateNode(nil), entry.Nodes...)
		mergeCandidateState(nodes, state)
		if sourceFilter == "all" || sourceFilter == definition.ID {
			allNodes = append(allNodes, nodes...)
		}
	}

	countryFilter := strings.ToUpper(strings.TrimSpace(r.URL.Query().Get("country")))
	query := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
	statusFilter := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("status")))
	filtered := make([]CandidateNode, 0, len(allNodes))
	for _, node := range allNodes {
		if countryFilter != "" && countryFilter != "ALL" && node.CountryCode != countryFilter {
			continue
		}
		if query != "" {
			haystack := strings.ToLower(strings.Join([]string{node.Address, node.IP, node.CountryCode, node.CountryName, node.City, node.ASN, node.Organization}, " "))
			if !strings.Contains(haystack, query) {
				continue
			}
		}
		if statusFilter == "selected" && !node.Selected {
			continue
		}
		if statusFilter == "verified" && (node.Verification == nil || !node.Verification.Success) {
			continue
		}
		if statusFilter == "failed" && (node.Verification == nil || node.Verification.Success) {
			continue
		}
		filtered = append(filtered, node)
	}
	sort.Slice(filtered, func(i, j int) bool {
		if filtered[i].Selected != filtered[j].Selected {
			return filtered[i].Selected
		}
		if filtered[i].CountryCode != filtered[j].CountryCode {
			return filtered[i].CountryCode < filtered[j].CountryCode
		}
		return filtered[i].Address < filtered[j].Address
	})

	page := parseBoundedInt(r.URL.Query().Get("page"), 1, 1, 100000)
	pageSize := parseBoundedInt(r.URL.Query().Get("page_size"), 30, 10, 100)
	total := len(filtered)
	start := (page - 1) * pageSize
	if start > total {
		start = total
	}
	end := start + pageSize
	if end > total {
		end = total
	}

	summaries := make([]candidateSourceSummary, 0, len(candidateSources))
	for _, definition := range candidateSources {
		entry := entries[definition.ID]
		countrySet := make(map[string]bool)
		for _, node := range entry.Nodes {
			if node.CountryCode != "" {
				countrySet[node.CountryCode] = true
			}
		}
		refreshedAt := ""
		if !entry.RefreshedAt.IsZero() {
			refreshedAt = entry.RefreshedAt.Format(time.RFC3339Nano)
		}
		summaries = append(summaries, candidateSourceSummary{ID: definition.ID, Name: definition.Name, Description: definition.Description, Total: len(entry.Nodes), Countries: len(countrySet), RefreshedAt: refreshedAt, Error: entry.Error})
	}
	countries := summarizeCandidateCountries(entries, state)
	writeJSON(w, http.StatusOK, map[string]any{
		"sources": summaries, "countries": countries, "items": filtered[start:end], "total": total,
		"page": page, "page_size": pageSize, "pages": int(mathCeil(total, pageSize)), "selection": candidateSelectionSummary(state),
		"capabilities": map[string]any{"random_preferred_min": 1, "random_preferred_max": 99, "custom_preferred": true, "proxyip_max": 8, "reverse_modes": []string{"proxyip", "socks5", "http", "https"}},
	})
}

func parseBoundedInt(raw string, fallback, minimum, maximum int) int {
	value, err := strconv.Atoi(raw)
	if err != nil || value < minimum || value > maximum {
		return fallback
	}
	return value
}

func mathCeil(total, pageSize int) int {
	if total == 0 {
		return 1
	}
	return (total + pageSize - 1) / pageSize
}

func summarizeCandidateCountries(entries map[string]candidateCacheEntry, state CandidateStateDocument) []candidateCountrySummary {
	byCode := make(map[string]*candidateCountrySummary)
	for _, entry := range entries {
		for _, node := range entry.Nodes {
			if node.CountryCode == "" {
				continue
			}
			item := byCode[node.CountryCode]
			if item == nil {
				item = &candidateCountrySummary{Code: node.CountryCode, Name: node.CountryName, Emoji: node.CountryEmoji}
				byCode[node.CountryCode] = item
			}
			item.Total++
			if saved, ok := state.Entries[node.ID]; ok {
				if saved.Verification.Success {
					item.Verified++
				}
				if saved.Selected {
					item.Selected++
				}
			}
		}
	}
	items := make([]candidateCountrySummary, 0, len(byCode))
	for _, item := range byCode {
		items = append(items, *item)
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].Total == items[j].Total {
			return items[i].Code < items[j].Code
		}
		return items[i].Total > items[j].Total
	})
	return items
}

func candidateSelectionSummary(state CandidateStateDocument) map[string]any {
	items := make([]CandidateStateEntry, 0)
	for _, entry := range state.Entries {
		if entry.Selected {
			entry.Node.Selected = true
			verification := entry.Verification
			entry.Node.Verification = &verification
			items = append(items, entry)
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].Node.Address < items[j].Node.Address })
	return map[string]any{"updated_at": state.UpdatedAt, "count": len(items), "items": items}
}

func (m *Monitor) findCandidate(ctx context.Context, sourceID, id string) (CandidateNode, error) {
	entry, err := m.loadCatalogSource(ctx, sourceID, false)
	if err != nil {
		return CandidateNode{}, err
	}
	for _, node := range entry.Nodes {
		if node.ID == id {
			return node, nil
		}
	}
	return CandidateNode{}, errors.New("candidate not found")
}

func (m *Monitor) handleCatalogAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !m.isAllowedRemote(r.RemoteAddr) || r.Header.Get("X-ProxyTunnel-Action") != "confirmed" || !sameOrigin(r) {
		http.Error(w, "confirmation required", http.StatusForbidden)
		return
	}
	var payload struct {
		Action   string `json:"action"`
		Source   string `json:"source"`
		ID       string `json:"id"`
		Selected bool   `json:"selected"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 32*1024)).Decode(&payload); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 70*time.Second)
	defer cancel()
	if payload.Action == "refresh" {
		for _, source := range candidateSources {
			if payload.Source != "" && payload.Source != "all" && source.ID != payload.Source {
				continue
			}
			if _, err := m.loadCatalogSource(ctx, source.ID, true); err != nil {
				writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
				return
			}
		}
		m.recordCatalogAction("catalog_refresh", true, "候选节点来源已刷新", r.RemoteAddr)
		writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": "候选节点来源已刷新"})
		return
	}

	node, err := m.findCandidate(ctx, strings.ToLower(payload.Source), payload.ID)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
		return
	}
	if payload.Action == "verify" {
		verification := m.verifyCandidate(ctx, node)
		m.candidateMu.Lock()
		state := loadCandidateState(m.cfg.CandidateStateFile)
		previous := state.Entries[node.ID]
		state.Entries[node.ID] = CandidateStateEntry{Node: node, Selected: previous.Selected && verification.Success, Verification: verification}
		err = writeCandidateState(m.cfg.CandidateStateFile, state)
		m.candidateMu.Unlock()
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to save verification"})
			return
		}
		message := "候选节点验证成功"
		if !verification.Success {
			message = "候选节点验证失败"
		}
		m.recordCatalogAction("candidate_verify", verification.Success, message+"："+node.Source+" "+node.IP, r.RemoteAddr)
		status := http.StatusOK
		if !verification.Success {
			status = http.StatusBadGateway
		}
		writeJSON(w, status, map[string]any{"success": verification.Success, "message": message, "verification": verification})
		return
	}
	if payload.Action == "select" {
		m.candidateMu.Lock()
		state := loadCandidateState(m.cfg.CandidateStateFile)
		entry, exists := state.Entries[node.ID]
		if payload.Selected && (!exists || !entry.Verification.Success) {
			m.candidateMu.Unlock()
			writeJSON(w, http.StatusConflict, map[string]string{"error": "candidate must pass verification before selection"})
			return
		}
		if payload.Selected && node.Source == "proxyip" {
			selectedProxyIPs := 0
			for _, current := range state.Entries {
				if current.Selected && current.Node.Source == "proxyip" && current.Node.ID != node.ID {
					selectedProxyIPs++
				}
			}
			if selectedProxyIPs >= 8 {
				m.candidateMu.Unlock()
				writeJSON(w, http.StatusConflict, map[string]string{"error": "ProxyIP selection is limited to 8"})
				return
			}
		}
		entry.Node = node
		entry.Selected = payload.Selected
		state.Entries[node.ID] = entry
		err = writeCandidateState(m.cfg.CandidateStateFile, state)
		m.candidateMu.Unlock()
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "unable to save selection"})
			return
		}
		message := "候选节点已加入自选列表"
		if !payload.Selected {
			message = "候选节点已移出自选列表"
		}
		m.recordCatalogAction("candidate_select", true, message+"："+node.Source+" "+node.IP, r.RemoteAddr)
		writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": message, "selection": candidateSelectionSummary(state)})
		return
	}
	writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unsupported catalog action"})
}

func (m *Monitor) recordCatalogAction(action string, success bool, message, remote string) {
	record := ActionRecord{Time: time.Now().Format(time.RFC3339Nano), Action: action, Success: success, Message: message, RemoteAddr: remoteIP(remote)}
	_ = appendJSONLine(m.cfg.HistoryDir+string(os.PathSeparator)+"actions-"+time.Now().Format("2006-01-02")+".jsonl", record)
}

func (m *Monitor) verifyCandidate(ctx context.Context, node CandidateNode) CandidateVerification {
	started := time.Now()
	verification := CandidateVerification{CheckedAt: started.Format(time.RFC3339Nano)}
	if !isPublicIP(node.IP) {
		verification.Error = "candidate IP is not public"
		return verification
	}
	if node.Source == "proxyip" {
		endpoint := "https://api.090227.xyz/check?proxyip=" + url.QueryEscape(node.IP)
		request, _ := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
		response, err := m.catalogClient.Do(request)
		if err != nil {
			verification.Error = err.Error()
			return verification
		}
		defer response.Body.Close()
		var result struct {
			Success      bool   `json:"success"`
			ProxyIP      string `json:"proxyIP"`
			Colo         string `json:"colo"`
			ProbeResults struct {
				IPv4 struct {
					OK   bool `json:"ok"`
					Exit struct {
						IP      string `json:"ip"`
						Country string `json:"country"`
						Colo    string `json:"colo"`
					} `json:"exit"`
				} `json:"ipv4"`
			} `json:"probe_results"`
		}
		if response.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(response.Body, 2<<20)).Decode(&result) != nil || !result.Success || !result.ProbeResults.IPv4.OK {
			verification.Error = "ProxyIP validation service rejected the candidate"
			return verification
		}
		verification.Success = true
		verification.LatencyMS = time.Since(started).Milliseconds()
		verification.EgressIP = result.ProbeResults.IPv4.Exit.IP
		verification.CountryCode = strings.ToUpper(result.ProbeResults.IPv4.Exit.Country)
		verification.CountryName = candidateCountryName(verification.CountryCode, node)
		verification.Colo = strings.ToUpper(result.ProbeResults.IPv4.Exit.Colo)
		if verification.Colo == "" {
			verification.Colo = strings.ToUpper(result.Colo)
		}
		verification.CountryMatched = node.CountryCode == "" || verification.CountryCode == node.CountryCode
		return verification
	}

	client, err := candidateHTTPClient(node)
	if err != nil {
		verification.Error = err.Error()
		return verification
	}
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://www.cloudflare.com/cdn-cgi/trace", nil)
	response, err := client.Do(request)
	if err != nil {
		verification.Error = err.Error()
		return verification
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		verification.Error = fmt.Sprintf("trace returned HTTP %d", response.StatusCode)
		return verification
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 128<<10))
	if err != nil {
		verification.Error = err.Error()
		return verification
	}
	trace := parseCandidateTrace(string(body))
	country := strings.ToUpper(trace["loc"])
	if country == "" {
		verification.Error = "trace did not return an egress country"
		return verification
	}
	verification.Success = true
	verification.LatencyMS = time.Since(started).Milliseconds()
	verification.EgressIP = trace["ip"]
	verification.CountryCode = country
	verification.CountryName = candidateCountryName(country, node)
	verification.Colo = strings.ToUpper(trace["colo"])
	verification.CountryMatched = node.CountryCode == "" || country == node.CountryCode
	return verification
}

func isPublicIP(raw string) bool {
	ip := net.ParseIP(strings.TrimSpace(raw))
	return ip != nil && !ip.IsPrivate() && !ip.IsLoopback() && !ip.IsUnspecified() && !ip.IsMulticast() && !ip.IsLinkLocalUnicast() && !ip.IsLinkLocalMulticast()
}

func candidateCountryName(code string, node CandidateNode) string {
	if code == node.CountryCode && node.CountryName != "" {
		return node.CountryName
	}
	if name := countryCatalog[code]; name != "" {
		return name
	}
	return code
}

func parseCandidateTrace(body string) map[string]string {
	result := make(map[string]string)
	for _, line := range strings.Split(body, "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok && key != "" {
			result[key] = value
		}
	}
	return result
}

func candidateHTTPClient(node CandidateNode) (*http.Client, error) {
	transport := &http.Transport{
		TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout: 8 * time.Second,
		IdleConnTimeout:     10 * time.Second,
		DisableKeepAlives:   true,
	}
	if node.Protocol == "socks5" {
		proxyAddress := net.JoinHostPort(node.IP, strconv.Itoa(node.Port))
		transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
			return dialSOCKS5(ctx, proxyAddress, address)
		}
	} else {
		proxyURL, err := url.Parse(node.Address)
		if err != nil || (proxyURL.Scheme != "http" && proxyURL.Scheme != "https") {
			return nil, errors.New("unsupported proxy address")
		}
		transport.Proxy = http.ProxyURL(proxyURL)
	}
	return &http.Client{Timeout: 18 * time.Second, Transport: transport}, nil
}

func dialSOCKS5(ctx context.Context, proxyAddress, targetAddress string) (net.Conn, error) {
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	connection, err := dialer.DialContext(ctx, "tcp", proxyAddress)
	if err != nil {
		return nil, err
	}
	fail := func(err error) (net.Conn, error) {
		_ = connection.Close()
		return nil, err
	}
	deadline := time.Now().Add(12 * time.Second)
	_ = connection.SetDeadline(deadline)
	if _, err := connection.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		return fail(err)
	}
	header := make([]byte, 2)
	if _, err := io.ReadFull(connection, header); err != nil || header[0] != 0x05 || header[1] != 0x00 {
		return fail(errors.New("SOCKS5 authentication negotiation failed"))
	}
	host, portText, err := net.SplitHostPort(targetAddress)
	if err != nil {
		return fail(err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return fail(errors.New("invalid SOCKS5 target port"))
	}
	request := []byte{0x05, 0x01, 0x00}
	if ip := net.ParseIP(host); ip != nil {
		if ipv4 := ip.To4(); ipv4 != nil {
			request = append(request, 0x01)
			request = append(request, ipv4...)
		} else {
			request = append(request, 0x04)
			request = append(request, ip.To16()...)
		}
	} else {
		if len(host) > 255 {
			return fail(errors.New("SOCKS5 target hostname is too long"))
		}
		request = append(request, 0x03, byte(len(host)))
		request = append(request, []byte(host)...)
	}
	request = append(request, byte(port>>8), byte(port))
	if _, err := connection.Write(request); err != nil {
		return fail(err)
	}
	reply := make([]byte, 4)
	if _, err := io.ReadFull(connection, reply); err != nil || reply[0] != 0x05 || reply[1] != 0x00 {
		return fail(errors.New("SOCKS5 connect request failed"))
	}
	remaining := 0
	switch reply[3] {
	case 0x01:
		remaining = 4 + 2
	case 0x04:
		remaining = 16 + 2
	case 0x03:
		length := make([]byte, 1)
		if _, err := io.ReadFull(connection, length); err != nil {
			return fail(err)
		}
		remaining = int(length[0]) + 2
	default:
		return fail(errors.New("SOCKS5 returned an invalid address type"))
	}
	if _, err := io.ReadFull(connection, make([]byte, remaining)); err != nil {
		return fail(err)
	}
	_ = connection.SetDeadline(time.Time{})
	return connection, nil
}

func (m *Monitor) cfOpsRequest(ctx context.Context, method, path string, body any) ([]byte, int, error) {
	if m.cfg.CloudflareOpsURL == "" || m.cfOpsToken == "" {
		return nil, 0, errors.New("Cloudflare operations bridge is not configured")
	}
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, 0, err
		}
		reader = bytes.NewReader(data)
	}
	request, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(m.cfg.CloudflareOpsURL, "/")+path, reader)
	if err != nil {
		return nil, 0, err
	}
	request.Header.Set("Authorization", "Bearer "+m.cfOpsToken)
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := m.cfOpsClient.Do(request)
	if err != nil {
		return nil, 0, err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	return data, response.StatusCode, err
}

func (m *Monitor) handleCloudflareConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		if m.cfg.CloudflareOpsURL == "" || m.cfOpsToken == "" {
			writeJSON(w, http.StatusOK, map[string]any{"configured": false, "reason": "Cloudflare operations bridge is not configured"})
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
		defer cancel()
		data, status, err := m.cfOpsRequest(ctx, http.MethodGet, "/v1/config", nil)
		if err != nil || status < 200 || status >= 300 {
			writeJSON(w, http.StatusBadGateway, map[string]any{"configured": true, "reachable": false, "error": "unable to read Cloudflare configuration"})
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(data)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodGet+", "+http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !m.isAllowedRemote(r.RemoteAddr) || r.Header.Get("X-ProxyTunnel-Action") != "confirmed" || !sameOrigin(r) {
		http.Error(w, "confirmation required", http.StatusForbidden)
		return
	}
	var payload struct {
		Action        string   `json:"action"`
		Mode          string   `json:"mode"`
		RandomCount   int      `json:"random_count"`
		SpecifiedPort int      `json:"specified_port"`
		CustomNodes   string   `json:"custom_nodes"`
		CandidateIDs  []string `json:"candidate_ids"`
		Global        bool     `json:"global"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 512<<10)).Decode(&payload); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request"})
		return
	}
	var path string
	var requestBody any
	if payload.Action == "subscription" {
		if payload.Mode != "random" && payload.Mode != "custom" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unsupported subscription mode"})
			return
		}
		if payload.Mode == "random" && (payload.RandomCount < 1 || payload.RandomCount > 99) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "random count must be between 1 and 99"})
			return
		}
		if payload.Mode == "custom" && (strings.TrimSpace(payload.CustomNodes) == "" || len(payload.CustomNodes) > 256<<10) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "custom preferred nodes are empty or too large"})
			return
		}
		path = "/v1/subscription"
		requestBody = map[string]any{"mode": payload.Mode, "random_count": payload.RandomCount, "specified_port": payload.SpecifiedPort, "custom_nodes": payload.CustomNodes}
	} else if payload.Action == "reverse_proxy" {
		mode := strings.ToLower(payload.Mode)
		if mode != "auto" && mode != "proxyip" && mode != "socks5" && mode != "http" && mode != "https" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unsupported reverse proxy mode"})
			return
		}
		addresses := make([]string, 0, len(payload.CandidateIDs))
		if mode != "auto" {
			m.candidateMu.Lock()
			state := loadCandidateState(m.cfg.CandidateStateFile)
			m.candidateMu.Unlock()
			for _, id := range payload.CandidateIDs {
				entry, ok := state.Entries[id]
				if !ok || !entry.Selected || !entry.Verification.Success || entry.Node.Source != mode {
					writeJSON(w, http.StatusConflict, map[string]string{"error": "every candidate must be selected, verified, and match the chosen mode"})
					return
				}
				addresses = append(addresses, entry.Node.Address)
			}
			if mode == "proxyip" && (len(addresses) < 1 || len(addresses) > 8) {
				writeJSON(w, http.StatusConflict, map[string]string{"error": "select between 1 and 8 verified ProxyIP candidates"})
				return
			}
			if mode != "proxyip" && len(addresses) != 1 {
				writeJSON(w, http.StatusConflict, map[string]string{"error": "select exactly one verified reverse proxy candidate"})
				return
			}
		}
		path = "/v1/reverse-proxy"
		requestBody = map[string]any{"mode": mode, "addresses": addresses, "global": payload.Global}
	} else {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unsupported Cloudflare action"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	data, status, err := m.cfOpsRequest(ctx, http.MethodPut, path, requestBody)
	if err != nil || status < 200 || status >= 300 {
		message := "Cloudflare configuration update failed"
		if len(data) > 0 {
			var failure map[string]any
			if json.Unmarshal(data, &failure) == nil {
				if detail, ok := failure["error"].(string); ok && detail != "" {
					message = detail
				}
			}
		}
		m.recordCatalogAction("cloudflare_"+payload.Action, false, message, r.RemoteAddr)
		writeJSON(w, http.StatusBadGateway, map[string]any{"success": false, "message": message})
		return
	}
	m.recordCatalogAction("cloudflare_"+payload.Action, true, "Cloudflare 配置已更新并保留备份", r.RemoteAddr)
	go func() {
		time.Sleep(3 * time.Second)
		providerPath := "/providers/proxies/" + url.PathEscape(m.cfg.ProviderName)
		_, _, _ = m.controllerRequest(http.MethodPut, providerPath)
		m.refresh()
	}()
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}
