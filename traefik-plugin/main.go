// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0

package traefik_plugin

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

type Config struct {
	ServiceName   string `json:"serviceName"`
	JobName       string `json:"jobName"`
	GroupName     string `json:"groupName"`
	NomadAddr     string `json:"nomadAddr"`
	ConsulAddr    string `json:"consulAddr"`
	RedisAddr     string `json:"redisAddr"`
	RedisPassword string `json:"redisPassword"`
	NomadToken    string `json:"nomadToken"`
	ConsulToken   string `json:"consulToken"`
	ActivityStore string `json:"activityStore"`
	JobSpecStore  string `json:"jobSpecStore"` // consul or redis
	Timeout       string `json:"timeout"`
	ProbePath     string `json:"probePath"`
	JobSpecKey    string `json:"jobSpecKey"`
}

func CreateConfig() *Config {
	return &Config{
		Timeout:   "30s",
		ProbePath: "/healthz",
	}
}

type ScaleWaker struct {
	next          http.Handler
	name          string
	config        *Config
	nomadAddr     string
	consulAddr    string
	redisAddr     string
	redisPass     string
	nomadToken    string
	consulToken   string
	activityStore string
	jobSpecStore  string
	timeout       time.Duration
	probePath     string
	jobName       string
	group         string
	service       string
	client        *http.Client
	logger        *slog.Logger
	observability *wakeObservability

	// wakeupLocks prevents multiple concurrent scale-ups for the same service
	wakeupLocks sync.Map // map[string]*wakeupState

	// endpointCache caches recently resolved endpoints to skip Consul+Nomad round-trips
	endpointCache sync.Map // map[service]*cachedEndpoint
}

// wakeupState tracks the wake-up state for a service using a simple mutex
type wakeupState struct {
	mu sync.Mutex
}

// cachedEndpoint holds a recently resolved endpoint to avoid repeated Consul+Nomad lookups.
type cachedEndpoint struct {
	url      *url.URL
	cachedAt time.Time
}

const endpointCacheTTL = 30 * time.Second

type consulServiceEntry struct {
	Node struct {
		Address string `json:"Address"`
	} `json:"Node"`
	Service struct {
		Address string `json:"Address"`
		Port    int    `json:"Port"`
	} `json:"Service"`
}

type nomadJobInfo struct {
	Status     string              `json:"Status"`
	TaskGroups []nomadJobTaskGroup `json:"TaskGroups"`
}

type nomadJobTaskGroup struct {
	Name  string `json:"Name"`
	Count int    `json:"Count"`
}

// nomadAllocation represents the subset of Nomad allocation fields we need.
// The list endpoint (/v1/job/:id/allocations) returns stubs — AllocatedResources
// may be nil or sparse. Use getNomadAllocation (singular) for full details.
type nomadAllocation struct {
	ID           string `json:"ID"`
	TaskGroup    string `json:"TaskGroup"`
	ClientStatus string `json:"ClientStatus"`
	TaskStates   map[string]struct {
		State string `json:"State"`
	} `json:"TaskStates"`
	DeploymentStatus *struct {
		Healthy *bool `json:"Healthy"`
	} `json:"DeploymentStatus"`
	Resources struct {
		Networks []nomadAllocNetwork `json:"Networks"`
	} `json:"Resources"`
	AllocatedResources *struct {
		Shared struct {
			Networks []nomadAllocNetwork `json:"Networks"`
		} `json:"Shared"`
		Networks []nomadAllocNetwork `json:"Networks"`
	} `json:"AllocatedResources"`
}

type nomadAllocNetwork struct {
	IP            string              `json:"IP"`
	DynamicPorts  []nomadAllocDynPort `json:"DynamicPorts"`
	ReservedPorts []nomadAllocDynPort `json:"ReservedPorts"`
}

type nomadAllocDynPort struct {
	Label string `json:"Label"`
	Value int    `json:"Value"`
	To    int    `json:"To"`
}

var errWaitForHealthyTimeout = errors.New("timeout waiting for service")

type waitForHealthyTimeoutError struct {
	service string
}

func (e waitForHealthyTimeoutError) Error() string {
	return fmt.Sprintf("%s %s", errWaitForHealthyTimeout, e.service)
}

func (e waitForHealthyTimeoutError) Is(target error) bool {
	return target == errWaitForHealthyTimeout
}

func New(ctx context.Context, next http.Handler, config *Config, name string) (http.Handler, error) {
	if config == nil {
		return nil, errors.New("config required")
	}

	timeoutText := strings.TrimSpace(config.Timeout)
	if timeoutText == "" {
		timeoutText = "30s"
	}

	timeout, err := time.ParseDuration(timeoutText)
	if err != nil {
		return nil, fmt.Errorf("invalid timeout: %w", err)
	}
	probePath := normalizeProbePath(config.ProbePath)

	client := &http.Client{Timeout: 10 * time.Second}

	nomadAddr := coalesce(config.NomadAddr, os.Getenv("S2Z_NOMAD_ADDR"), "http://nomad.service.consul:4646")
	consulAddr := coalesce(config.ConsulAddr, os.Getenv("S2Z_CONSUL_ADDR"), "http://consul.service.consul:8500")
	redisAddr := coalesce(config.RedisAddr, os.Getenv("S2Z_REDIS_ADDR"))
	redisPass := coalesce(config.RedisPassword, os.Getenv("S2Z_REDIS_PASSWORD"))
	nomadToken := coalesce(config.NomadToken, os.Getenv("S2Z_NOMAD_TOKEN"))
	consulToken := coalesce(config.ConsulToken, os.Getenv("S2Z_CONSUL_TOKEN"))
	if nomadToken == "" {
		nomadToken = readBootstrapToken("NOMAD_S2Z_TOKEN")
	}
	if consulToken == "" {
		consulToken = readBootstrapToken("CONSUL_S2Z_TOKEN")
	}
	activityStore := coalesce(config.ActivityStore, os.Getenv("S2Z_ACTIVITY_STORE"), "consul")
	jobSpecStore := coalesce(config.JobSpecStore, os.Getenv("S2Z_JOB_SPEC_STORE"), "consul")
	if strings.EqualFold(activityStore, "redis") && redisAddr == "" {
		activityStore = "consul"
	}
	if strings.EqualFold(jobSpecStore, "redis") && redisAddr == "" {
		jobSpecStore = "consul"
	}

	return &ScaleWaker{
		next:          next,
		name:          name,
		config:        config,
		nomadAddr:     strings.TrimRight(nomadAddr, "/"),
		consulAddr:    strings.TrimRight(consulAddr, "/"),
		redisAddr:     redisAddr,
		redisPass:     redisPass,
		nomadToken:    nomadToken,
		consulToken:   consulToken,
		activityStore: activityStore,
		jobSpecStore:  jobSpecStore,
		timeout:       timeout,
		probePath:     probePath,
		jobName:       config.JobName,
		group:         config.GroupName,
		service:       config.ServiceName,
		client:        client,
		logger:        newPluginLogger(name),
		observability: defaultWakeObservabilityInstance(),
	}, nil
}

func coalesce(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func normalizeProbePath(raw string) string {
	probePath := strings.TrimSpace(raw)
	if probePath == "" {
		return "/healthz"
	}
	if !strings.HasPrefix(probePath, "/") {
		probePath = "/" + probePath
	}
	return probePath
}

func (s *ScaleWaker) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	ctx := req.Context()
	service, job, group := s.resolveTarget(req)
	logger := s.log().With("service", service, "job", job, "group", group, "host", req.Host, "path", req.URL.Path)
	if service == "" || job == "" || group == "" {
		logger.WarnContext(ctx, "missing service mapping")
		http.Error(rw, "missing service mapping", http.StatusServiceUnavailable)
		return
	}

	// Check endpoint cache first — avoids Consul+Nomad round-trips for recently woken services
	if cached := s.getCachedEndpoint(service); cached != nil {
		if s.probeEndpointHealth(ctx, cached) {
			logger.InfoContext(ctx, "serving from endpoint cache", "target", cached.String())
			if err := s.recordActivity(ctx, service); err != nil {
				logger.WarnContext(ctx, "activity store update failed", "error", err)
			}
			if !s.proxyToWithRetry(rw, req, cached, service, job, group, logger) {
				logger.ErrorContext(ctx, "proxy failed after retry (cached)")
				s.invalidateEndpointCache(service)
			}
			return
		}
		// Cached endpoint unreachable — invalidate and fall through to normal path
		s.invalidateEndpointCache(service)
		logger.InfoContext(ctx, "cached endpoint unreachable, falling through", "target", cached.String())
	}

	endpoint, healthy, err := s.getHealthyEndpoint(ctx, service)
	if err != nil {
		logger.WarnContext(ctx, "consul health lookup failed, falling through to nomad-direct path", "error", err)
		healthy = false
	}

	// If Consul says healthy, verify endpoint is actually reachable
	// (handles stale/orphaned Consul catalog entries)
	if healthy {
		if !s.isEndpointReachable(endpoint) {
			if endpoint != nil {
				logger.WarnContext(ctx, "consul returned stale endpoint", "target", endpoint.String())
			}
			healthy = false
		}
	}

	// Stale-guard: if Consul says healthy but Nomad job has count=0,
	// the endpoint is from a draining allocation — force wake path.
	if healthy {
		count, countErr := s.getJobGroupCount(ctx, job, group)
		if countErr == nil && count == 0 {
			if endpoint != nil {
				logger.WarnContext(ctx, "stale consul endpoint detected (nomad count=0)", "target", endpoint.String())
			}
			healthy = false
		}
	}

	// Cache after Consul returns healthy and passes all stale guards
	if healthy {
		s.cacheEndpoint(service, endpoint)
	}

	if !healthy {
		logger.InfoContext(ctx, "service unhealthy, attempting wake")
		endpoint, err = s.wakeUpService(ctx, service, job, group)
		if err != nil {
			logger.ErrorContext(ctx, "service wake-up failed", "error", err)
			http.Error(rw, fmt.Sprintf("wake up: %v", err), http.StatusServiceUnavailable)
			return
		}
		if endpoint == nil {
			logger.ErrorContext(ctx, "wake returned nil endpoint without error", "service", service)
			http.Error(rw, "internal error: nil endpoint", http.StatusServiceUnavailable)
			return
		}
		logger.InfoContext(ctx, "service wake-up completed", "target", endpoint.String())
		s.cacheEndpoint(service, endpoint)
	}

	if err := s.recordActivity(ctx, service); err != nil {
		logger.WarnContext(ctx, "activity store update failed", "error", err)
	}

	// Proxy with single retry through wake path on failure.
	if !s.proxyToWithRetry(rw, req, endpoint, service, job, group, logger) {
		logger.ErrorContext(ctx, "proxy failed after retry")
	}
}

func (s *ScaleWaker) log() *slog.Logger {
	if s != nil && s.logger != nil {
		return s.logger
	}
	return newPluginLogger("scalewaker")
}

// isEndpointReachable quickly checks if an endpoint can accept TCP connections
func (s *ScaleWaker) isEndpointReachable(endpoint *url.URL) bool {
	if endpoint == nil {
		return false
	}
	conn, err := net.DialTimeout("tcp", endpoint.Host, 500*time.Millisecond)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

func (s *ScaleWaker) getCachedEndpoint(service string) *url.URL {
	val, ok := s.endpointCache.Load(service)
	if !ok {
		return nil
	}
	ce := val.(*cachedEndpoint)
	if time.Since(ce.cachedAt) > endpointCacheTTL {
		s.endpointCache.Delete(service)
		return nil
	}
	return ce.url
}

func (s *ScaleWaker) cacheEndpoint(service string, endpoint *url.URL) {
	if endpoint == nil {
		return
	}
	s.endpointCache.Store(service, &cachedEndpoint{
		url:      endpoint,
		cachedAt: time.Now(),
	})
}

func (s *ScaleWaker) invalidateEndpointCache(service string) {
	s.endpointCache.Delete(service)
}

// getOrCreateWakeupState returns the wakeup state for a service, creating one if needed
func (s *ScaleWaker) getOrCreateWakeupState(service string) *wakeupState {
	actual, _ := s.wakeupLocks.LoadOrStore(service, &wakeupState{})
	return actual.(*wakeupState)
}

// wakeUpService handles waking up a service with proper locking
// Only one goroutine performs the actual wake-up, others wait by polling
func (s *ScaleWaker) wakeUpService(ctx context.Context, service, job, group string) (*url.URL, error) {
	ws := s.getOrCreateWakeupState(service)

	// Try to acquire the lock - this serializes wake-up attempts
	ws.mu.Lock()
	defer ws.mu.Unlock()

	// Check if service became healthy while we waited for the lock.
	// If Consul is unreachable, treat as "not healthy" and proceed with wake.
	endpoint, healthy, err := s.getHealthyEndpoint(ctx, service)
	if err != nil {
		s.log().With("service", service).WarnContext(ctx, "consul health check failed in wake path, proceeding", "error", err)
		healthy = false
	}
	obs := s.observabilityMetrics()
	if healthy && s.isEndpointReachable(endpoint) {
		// Double-check: is this a stale endpoint from a draining allocation?
		count, countErr := s.getJobGroupCount(ctx, job, group)
		if countErr == nil && count == 0 {
			// Stale — fall through to wake
		} else {
			start := time.Now()
			obs.observeAttempt()
			obs.observeOutcome(wakeResultAlreadyHealthy, time.Since(start))
			return endpoint, nil
		}
	}

	// We're the one doing the wake-up
	start := time.Now()
	obs.observeAttempt()

	if err := s.ensureJob(ctx, job); err != nil {
		obs.observeOutcome(wakeResultEnsureJobError, time.Since(start))
		return nil, fmt.Errorf("ensure job: %w", err)
	}
	if err := s.scaleUp(ctx, job, group); err != nil {
		// If scaling fails, still wait for the service via Nomad
		// (e.g., another deployment is already in progress).
		endpoint, waitErr := s.waitForNomadAllocation(ctx, job, group)
		if waitErr == nil {
			obs.observeOutcome(wakeResultSuccessAfterScaleError, time.Since(start))
			return endpoint, nil
		}
		obs.observeOutcome(wakeResultScaleUpError, time.Since(start))
		return nil, fmt.Errorf("scale up: %w", err)
	}

	// Poll Nomad directly for allocation health — bypasses Consul registration lag
	endpoint, err = s.waitForNomadAllocation(ctx, job, group)
	if err != nil {
		obs.observeOutcome(wakeResultForWaitError(err), time.Since(start))
		return nil, fmt.Errorf("wait allocation: %w", err)
	}

	obs.observeOutcome(wakeResultSuccess, time.Since(start))
	return endpoint, nil
}

func (s *ScaleWaker) resolveTarget(req *http.Request) (string, string, string) {
	service := s.service
	job := s.jobName
	group := s.group

	if service == "" {
		host := req.Host
		if strings.Contains(host, ":") {
			if parsed, _, err := net.SplitHostPort(host); err == nil {
				host = parsed
			} else {
				host = strings.Split(host, ":")[0]
			}
		}
		service = strings.TrimSuffix(host, ".localhost")
	}

	if job == "" {
		job = service
	}
	if group == "" {
		group = "main"
	}

	return service, job, group
}

func (s *ScaleWaker) getHealthyEndpoint(ctx context.Context, service string) (*url.URL, bool, error) {
	endpoint := fmt.Sprintf("%s/v1/health/service/%s?passing=1", s.consulAddr, url.PathEscape(service))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, false, err
	}
	s.addConsulToken(req)

	resp, err := s.client.Do(req)
	if err != nil {
		return nil, false, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, false, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, false, fmt.Errorf("consul health status %d", resp.StatusCode)
	}

	var entries []consulServiceEntry
	if err := json.NewDecoder(resp.Body).Decode(&entries); err != nil {
		return nil, false, err
	}
	if len(entries) == 0 {
		return nil, false, nil
	}

	addr := entries[0].Service.Address
	if addr == "" {
		addr = entries[0].Node.Address
	}
	if addr == "" || entries[0].Service.Port == 0 {
		return nil, false, fmt.Errorf("missing service address")
	}

	url := &url.URL{Scheme: "http", Host: fmt.Sprintf("%s:%d", addr, entries[0].Service.Port)}
	return url, true, nil
}

func (s *ScaleWaker) ensureJob(ctx context.Context, job string) error {
	status, err := s.jobStatus(ctx, job)
	if err != nil {
		return err
	}
	if status != "not-found" && status != "dead" && status != "stopped" {
		return nil
	}

	specKey := s.jobSpecKey(job)
	spec, err := s.getJobSpec(ctx, specKey)
	if err != nil {
		return err
	}

	payload, err := wrapJobRegister(spec)
	if err != nil {
		return err
	}

	endpoint := fmt.Sprintf("%s/v1/jobs", s.nomadAddr)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	s.addNomadToken(req)

	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("job register status %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}

	return nil
}

func (s *ScaleWaker) jobStatus(ctx context.Context, job string) (string, error) {
	endpoint := fmt.Sprintf("%s/v1/job/%s", s.nomadAddr, url.PathEscape(job))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return "", err
	}
	s.addNomadToken(req)

	resp, err := s.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return "not-found", nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("job status %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}

	var info nomadJobInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return "", err
	}

	return strings.ToLower(info.Status), nil
}

func wrapJobRegister(raw []byte) ([]byte, error) {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, fmt.Errorf("job spec must be JSON: %w", err)
	}

	// Check if already wrapped
	if _, ok := obj["Job"]; ok {
		// Need to unwrap, fix Stop, and rewrap
		var wrapper struct {
			Job map[string]interface{} `json:"Job"`
		}
		if err := json.Unmarshal(raw, &wrapper); err != nil {
			return nil, err
		}
		wrapper.Job["Stop"] = false
		return json.Marshal(wrapper)
	}

	// Not wrapped - fix Stop and wrap
	var jobObj map[string]interface{}
	if err := json.Unmarshal(raw, &jobObj); err != nil {
		return nil, err
	}
	jobObj["Stop"] = false

	wrapped := map[string]interface{}{"Job": jobObj}
	return json.Marshal(wrapped)
}

func (s *ScaleWaker) jobSpecKey(job string) string {
	if strings.TrimSpace(s.config.JobSpecKey) != "" {
		return s.config.JobSpecKey
	}
	return "scale-to-zero/jobs/" + strings.TrimPrefix(job, "/")
}

func (s *ScaleWaker) getJobSpec(ctx context.Context, key string) ([]byte, error) {
	if s.jobSpecStore == "redis" && s.redisAddr != "" {
		return s.getRedisValue(ctx, key)
	}
	return s.getConsulKV(ctx, key)
}

func (s *ScaleWaker) getConsulKV(ctx context.Context, key string) ([]byte, error) {
	endpoint := fmt.Sprintf("%s/v1/kv/%s?raw", s.consulAddr, url.PathEscape(key))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	s.addConsulToken(req)

	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, fmt.Errorf("job spec not found at %s", key)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("consul kv status %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}

	return io.ReadAll(resp.Body)
}

// getRedisValue retrieves a value from Redis using RESP protocol with
// buffered, length-based reads. Supports payloads up to several MB.
func (s *ScaleWaker) getRedisValue(ctx context.Context, key string) ([]byte, error) {
	conn, err := net.DialTimeout("tcp", s.redisAddr, 5*time.Second)
	if err != nil {
		return nil, fmt.Errorf("redis connect: %w", err)
	}
	defer conn.Close()

	// Set deadline based on context
	if deadline, ok := ctx.Deadline(); ok {
		conn.SetDeadline(deadline)
	} else {
		conn.SetDeadline(time.Now().Add(5 * time.Second))
	}

	// AUTH if password is set
	if s.redisPass != "" {
		if err := s.respAuth(conn); err != nil {
			return nil, err
		}
	}

	// GET command in RESP format
	getCmd := fmt.Sprintf("*2\r\n$3\r\nGET\r\n$%d\r\n%s\r\n", len(key), key)
	if _, err := conn.Write([]byte(getCmd)); err != nil {
		return nil, fmt.Errorf("redis get write: %w", err)
	}

	return s.respReadBulkString(conn, key)
}

// respAuth sends AUTH and reads the +OK response.
func (s *ScaleWaker) respAuth(conn net.Conn) error {
	authCmd := fmt.Sprintf("*2\r\n$4\r\nAUTH\r\n$%d\r\n%s\r\n", len(s.redisPass), s.redisPass)
	if _, err := conn.Write([]byte(authCmd)); err != nil {
		return fmt.Errorf("redis auth write: %w", err)
	}
	line, err := respReadLine(conn)
	if err != nil {
		return fmt.Errorf("redis auth read: %w", err)
	}
	if !strings.HasPrefix(line, "+OK") {
		return fmt.Errorf("redis auth failed: %s", line)
	}
	return nil
}

// respReadLine reads bytes one-at-a-time until it finds \r\n.
// Used only for short protocol lines (<1 KB), not bulk data.
func respReadLine(conn net.Conn) (string, error) {
	var buf []byte
	b := make([]byte, 1)
	for {
		_, err := io.ReadFull(conn, b)
		if err != nil {
			return "", err
		}
		buf = append(buf, b[0])
		if len(buf) >= 2 && buf[len(buf)-2] == '\r' && buf[len(buf)-1] == '\n' {
			return string(buf[:len(buf)-2]), nil
		}
		if len(buf) > 1024 {
			return "", fmt.Errorf("resp line too long")
		}
	}
}

// respReadBulkString parses a RESP bulk-string response using the
// declared length, reading exactly that number of bytes via io.ReadFull.
func (s *ScaleWaker) respReadBulkString(conn net.Conn, key string) ([]byte, error) {
	// Read the first line: $<length>\r\n  or  $-1\r\n  or  -ERR ...\r\n
	line, err := respReadLine(conn)
	if err != nil {
		return nil, fmt.Errorf("redis get read: %w", err)
	}

	if strings.HasPrefix(line, "$-1") {
		return nil, fmt.Errorf("job spec not found at %s", key)
	}
	if strings.HasPrefix(line, "-") {
		return nil, fmt.Errorf("redis error: %s", strings.TrimSpace(line[1:]))
	}
	if !strings.HasPrefix(line, "$") {
		return nil, fmt.Errorf("unexpected redis response: %.50s", line)
	}

	// Parse declared payload length
	var length int
	if _, err := fmt.Sscanf(line, "$%d", &length); err != nil {
		return nil, fmt.Errorf("invalid bulk string length: %w", err)
	}
	if length < 0 {
		return nil, fmt.Errorf("job spec not found at %s", key)
	}
	const maxPayload = 16 * 1024 * 1024 // 16 MB safety limit
	if length > maxPayload {
		return nil, fmt.Errorf("redis payload too large: %d bytes (max %d)", length, maxPayload)
	}

	// Read exactly `length` bytes of data + trailing \r\n
	data := make([]byte, length+2) // +2 for trailing \r\n
	if _, err := io.ReadFull(conn, data); err != nil {
		return nil, fmt.Errorf("redis bulk read: %w", err)
	}

	return data[:length], nil
}

func (s *ScaleWaker) scaleUp(ctx context.Context, job, group string) error {
	payload := map[string]interface{}{
		"Count":  1,
		"Target": map[string]string{"Group": group},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	endpoint := fmt.Sprintf("%s/v1/job/%s/scale", s.nomadAddr, url.PathEscape(job))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	s.addNomadToken(req)

	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(resp.Body)
		body := strings.TrimSpace(string(msg))
		if resp.StatusCode == http.StatusBadRequest && strings.Contains(strings.ToLower(body), "scaling blocked due to active deployment") {
			return nil
		}
		return fmt.Errorf("nomad scale status %d: %s", resp.StatusCode, body)
	}

	return nil
}

func (s *ScaleWaker) waitForHealthy(ctx context.Context, service string) (*url.URL, error) {
	deadline := time.Now().Add(s.timeout)
	var lastIndex string
	for {
		if time.Now().After(deadline) {
			return nil, waitForHealthyTimeoutError{service: service}
		}

		remaining := time.Until(deadline)
		wait := 5 * time.Second
		if remaining < wait {
			wait = remaining
		}

		endpoint, healthy, index, err := s.getHealthyEndpointBlocking(ctx, service, lastIndex, wait)
		if err != nil {
			return nil, err
		}
		if healthy {
			return endpoint, nil
		}
		if index != "" {
			lastIndex = index
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}
	}
}

func (s *ScaleWaker) getHealthyEndpointBlocking(ctx context.Context, service, index string, wait time.Duration) (*url.URL, bool, string, error) {
	endpoint := fmt.Sprintf("%s/v1/health/service/%s?passing=1&wait=%s", s.consulAddr, url.PathEscape(service), wait.String())
	if index != "" {
		endpoint += "&index=" + url.QueryEscape(index)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, false, "", err
	}
	s.addConsulToken(req)

	resp, err := s.client.Do(req)
	if err != nil {
		return nil, false, "", err
	}
	defer resp.Body.Close()

	newIndex := resp.Header.Get("X-Consul-Index")

	if resp.StatusCode == http.StatusNotFound {
		return nil, false, newIndex, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, false, newIndex, fmt.Errorf("consul health status %d", resp.StatusCode)
	}

	var entries []consulServiceEntry
	if err := json.NewDecoder(resp.Body).Decode(&entries); err != nil {
		return nil, false, newIndex, err
	}
	if len(entries) == 0 {
		return nil, false, newIndex, nil
	}

	addr := entries[0].Service.Address
	if addr == "" {
		addr = entries[0].Node.Address
	}
	if addr == "" || entries[0].Service.Port == 0 {
		return nil, false, newIndex, fmt.Errorf("missing service address")
	}

	url := &url.URL{Scheme: "http", Host: fmt.Sprintf("%s:%d", addr, entries[0].Service.Port)}
	return url, true, newIndex, nil
}

func (s *ScaleWaker) recordActivity(ctx context.Context, service string) error {
	key := fmt.Sprintf("scale-to-zero/activity/%s", strings.TrimPrefix(service, "/"))
	if strings.EqualFold(s.activityStore, "redis") && s.redisAddr != "" {
		return s.setRedisValue(ctx, key, time.Now().UTC().Format(time.RFC3339Nano))
	}

	endpoint := fmt.Sprintf("%s/v1/kv/%s", s.consulAddr, url.PathEscape(key))
	payload := time.Now().UTC().Format(time.RFC3339Nano)

	req, err := http.NewRequestWithContext(ctx, http.MethodPut, endpoint, strings.NewReader(payload))
	if err != nil {
		return err
	}
	s.addConsulToken(req)

	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("consul kv status %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}

	return nil
}

func (s *ScaleWaker) addNomadToken(req *http.Request) {
	if s.nomadToken != "" {
		req.Header.Set("X-Nomad-Token", s.nomadToken)
	}
}

func (s *ScaleWaker) addConsulToken(req *http.Request) {
	if s.consulToken != "" {
		req.Header.Set("X-Consul-Token", s.consulToken)
	}
}

// setRedisValue writes a value to Redis using simple RESP protocol
func (s *ScaleWaker) setRedisValue(ctx context.Context, key, value string) error {
	conn, err := net.DialTimeout("tcp", s.redisAddr, 5*time.Second)
	if err != nil {
		return fmt.Errorf("redis connect: %w", err)
	}
	defer conn.Close()

	if deadline, ok := ctx.Deadline(); ok {
		conn.SetDeadline(deadline)
	} else {
		conn.SetDeadline(time.Now().Add(5 * time.Second))
	}

	if s.redisPass != "" {
		if err := s.respAuth(conn); err != nil {
			return err
		}
	}

	setCmd := fmt.Sprintf("*3\r\n$3\r\nSET\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n", len(key), key, len(value), value)
	if _, err := conn.Write([]byte(setCmd)); err != nil {
		return fmt.Errorf("redis set write: %w", err)
	}

	line, err := respReadLine(conn)
	if err != nil {
		return fmt.Errorf("redis set read: %w", err)
	}
	if !strings.HasPrefix(line, "+OK") {
		return fmt.Errorf("redis set failed: %s", strings.TrimSpace(line))
	}

	return nil
}

// getJobGroupCount returns the configured count for a task group from the Nomad
// job definition. Used as a stale-guard: if count=0, any Consul "healthy"
// endpoint is from a draining allocation.
func (s *ScaleWaker) getJobGroupCount(ctx context.Context, job, group string) (int, error) {
	endpoint := fmt.Sprintf("%s/v1/job/%s", s.nomadAddr, url.PathEscape(job))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return -1, err
	}
	s.addNomadToken(req)

	resp, err := s.client.Do(req)
	if err != nil {
		return -1, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return 0, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(resp.Body)
		return -1, fmt.Errorf("nomad job status %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}

	var info nomadJobInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return -1, err
	}

	for _, tg := range info.TaskGroups {
		if tg.Name == group {
			return tg.Count, nil
		}
	}
	return 0, nil
}

// getNomadAllocations fetches allocations for a job from the Nomad API.
// Uses ?resources=true to include network/port info in the response.
func (s *ScaleWaker) getNomadAllocations(ctx context.Context, job string) ([]nomadAllocation, error) {
	endpoint := fmt.Sprintf("%s/v1/job/%s/allocations?resources=true", s.nomadAddr, url.PathEscape(job))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	s.addNomadToken(req)

	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("nomad allocations status %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}

	var allocs []nomadAllocation
	if err := json.NewDecoder(resp.Body).Decode(&allocs); err != nil {
		return nil, err
	}
	return allocs, nil
}

// getNomadAllocation fetches the full allocation details for a single allocation.
// Unlike the list endpoint, this returns the complete Allocation object with
// AllocatedResources.Shared.Networks populated.
func (s *ScaleWaker) getNomadAllocation(ctx context.Context, allocID string) (*nomadAllocation, error) {
	endpoint := fmt.Sprintf("%s/v1/allocation/%s", s.nomadAddr, url.PathEscape(allocID))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	s.addNomadToken(req)

	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("nomad allocation status %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}

	var alloc nomadAllocation
	if err := json.NewDecoder(resp.Body).Decode(&alloc); err != nil {
		return nil, err
	}
	return &alloc, nil
}

// extractAllocEndpoint returns the first usable address:port from a Nomad allocation.
func extractAllocEndpoint(alloc nomadAllocation) *url.URL {
	// Try AllocatedResources.Shared.Networks (Nomad >= 0.9, full allocation response)
	if alloc.AllocatedResources != nil {
		for _, net := range alloc.AllocatedResources.Shared.Networks {
			if u := firstPort(net); u != nil {
				return u
			}
		}
		// Some Nomad versions put Networks at the top level of AllocatedResources
		for _, net := range alloc.AllocatedResources.Networks {
			if u := firstPort(net); u != nil {
				return u
			}
		}
	}
	// Fall back to Resources.Networks (legacy / always present on full alloc)
	for _, net := range alloc.Resources.Networks {
		if u := firstPort(net); u != nil {
			return u
		}
	}
	return nil
}

func firstPort(net nomadAllocNetwork) *url.URL {
	ip := net.IP
	if ip == "" {
		return nil
	}
	// Dynamic ports first (most common for services)
	for _, p := range net.DynamicPorts {
		if p.Value > 0 {
			return &url.URL{Scheme: "http", Host: fmt.Sprintf("%s:%d", ip, p.Value)}
		}
	}
	// Then reserved ports
	for _, p := range net.ReservedPorts {
		if p.Value > 0 {
			return &url.URL{Scheme: "http", Host: fmt.Sprintf("%s:%d", ip, p.Value)}
		}
	}
	return nil
}

// waitForNomadAllocation polls the Nomad API directly for a running, healthy
// allocation and returns its address. This bypasses the Consul registration
// pipeline entirely, eliminating the 2-8s lag between "Nomad knows it's healthy"
// and "Consul marks it passing".
func (s *ScaleWaker) waitForNomadAllocation(ctx context.Context, job, group string) (*url.URL, error) {
	deadline := time.Now().Add(s.timeout)
	logger := s.log().With("job", job, "group", group)

	for {
		if time.Now().After(deadline) {
			return nil, waitForHealthyTimeoutError{service: job + "/" + group}
		}

		allocs, err := s.getNomadAllocations(ctx, job)
		if err != nil {
			return nil, err
		}

		for _, alloc := range allocs {
			if alloc.TaskGroup != group {
				continue
			}
			if alloc.ClientStatus != "running" {
				continue
			}

			// Check if all tasks are running
			allTasksRunning := len(alloc.TaskStates) > 0
			for _, ts := range alloc.TaskStates {
				if ts.State != "running" {
					allTasksRunning = false
					break
				}
			}
			if !allTasksRunning {
				continue
			}

			// Try extracting endpoint from the list stub first
			endpoint := extractAllocEndpoint(alloc)
			if endpoint == nil {
				// List endpoint returns stubs — fetch full allocation for network info
				fullAlloc, err := s.getNomadAllocation(ctx, alloc.ID)
				if err != nil {
					logger.Warn("failed to fetch full allocation", "alloc_id", alloc.ID[:8], "err", err)
					continue
				}
				endpoint = extractAllocEndpoint(*fullAlloc)
			}
			if endpoint == nil {
				logger.Warn("allocation running but no network endpoint found", "alloc_id", alloc.ID[:8])
				continue
			}

			// Direct HTTP health probe — don't trust metadata alone
			if s.probeEndpointHealth(ctx, endpoint) {
				logger.Info("nomad allocation healthy",
					"alloc_id", alloc.ID[:8],
					"target", endpoint.String(),
				)
				return endpoint, nil
			}
		}

		// Adaptive backoff: start fast, slow down for slower services
		elapsed := time.Since(deadline.Add(-s.timeout))
		var pollInterval time.Duration
		switch {
		case elapsed < 5*time.Second:
			pollInterval = 500 * time.Millisecond
		case elapsed < 15*time.Second:
			pollInterval = 1 * time.Second
		default:
			pollInterval = 2 * time.Second
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(pollInterval):
		}
	}
}

// probeEndpointHealth does a direct HTTP GET to the configured probe path to
// verify the endpoint is actually serving traffic. Timeout is short (1s) since
// we just need to confirm the process is responsive.
func (s *ScaleWaker) probeEndpointHealth(ctx context.Context, endpoint *url.URL) bool {
	probeURL := endpoint.ResolveReference(&url.URL{Path: normalizeProbePath(s.probePath)}).String()
	probeCtx, cancel := context.WithTimeout(ctx, 1*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(probeCtx, http.MethodGet, probeURL, nil)
	if err != nil {
		return false
	}

	resp, err := s.client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	return resp.StatusCode >= 200 && resp.StatusCode < 400
}

// proxyToWithRetry attempts to proxy the request. On failure, it retries once
// through the full wake path to handle stale endpoints gracefully.
// Retry only happens if no bytes were written to the client (safe to restart).
func (s *ScaleWaker) proxyToWithRetry(rw http.ResponseWriter, req *http.Request, endpoint *url.URL, service, job, group string, logger *slog.Logger) bool {
	// First attempt
	recorder := &responseRecorder{inner: rw, statusCode: 200}
	s.doProxy(recorder, req, endpoint, logger)

	if !recorder.failed {
		return true
	}

	// Only retry if we haven't written anything to the client yet
	if recorder.wrote {
		target := "nil"
		if endpoint != nil {
			target = endpoint.String()
		}
		logger.WarnContext(req.Context(), "proxy failed after partial write, cannot retry",
			"failed_target", target,
		)
		return false
	}

	// Proxy failed — retry through wake path
	target := "nil"
	if endpoint != nil {
		target = endpoint.String()
	}
	logger.WarnContext(req.Context(), "proxy failed, retrying through wake path",
		"failed_target", target,
	)
	s.invalidateEndpointCache(service)

	retryEndpoint, err := s.wakeUpService(req.Context(), service, job, group)
	if err != nil {
		logger.ErrorContext(req.Context(), "retry wake-up failed", "error", err)
		http.Error(rw, fmt.Sprintf("retry wake up: %v", err), http.StatusServiceUnavailable)
		return false
	}

	if retryEndpoint != nil {
		logger.InfoContext(req.Context(), "retry wake-up succeeded, proxying", "target", retryEndpoint.String())
		s.proxyTo(rw, req, retryEndpoint, logger)
	} else {
		logger.ErrorContext(req.Context(), "retry wake returned nil endpoint")
		http.Error(rw, "internal error: nil endpoint on retry", http.StatusServiceUnavailable)
	}
	return retryEndpoint != nil
}

// responseRecorder wraps http.ResponseWriter to detect proxy failures without
// writing to the real writer. On the first attempt we buffer the proxy — if it
// fails we can retry. This only captures the error handler path.
type responseRecorder struct {
	inner      http.ResponseWriter
	statusCode int
	failed     bool
	wrote      bool
}

func (r *responseRecorder) Header() http.Header { return r.inner.Header() }
func (r *responseRecorder) Write(b []byte) (int, error) {
	r.wrote = true
	return r.inner.Write(b)
}
func (r *responseRecorder) WriteHeader(code int) {
	r.statusCode = code
	r.inner.WriteHeader(code)
}
func (r *responseRecorder) Flush() {
	if f, ok := r.inner.(http.Flusher); ok {
		f.Flush()
	}
}

// doProxy executes the reverse proxy. If the proxy's ErrorHandler fires, it
// sets recorder.failed = true.
func (s *ScaleWaker) doProxy(rw *responseRecorder, req *http.Request, target *url.URL, logger *slog.Logger) {
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		logger.WarnContext(r.Context(), "reverse proxy request failed", "error", err, "target", target.String())
		rw.failed = true
		// Don't write error to client yet — caller may retry
	}
	proxy.Director = func(r *http.Request) {
		r.URL.Scheme = target.Scheme
		r.URL.Host = target.Host
	}
	proxy.ServeHTTP(rw, req)
}

func (s *ScaleWaker) proxyTo(rw http.ResponseWriter, req *http.Request, target *url.URL, logger *slog.Logger) {
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(rw http.ResponseWriter, req *http.Request, err error) {
		logger.WarnContext(req.Context(), "reverse proxy request failed", "error", err, "target", target.String())
		http.Error(rw, fmt.Sprintf("proxy error: %v", err), http.StatusBadGateway)
	}
	proxy.Director = func(r *http.Request) {
		r.URL.Scheme = target.Scheme
		r.URL.Host = target.Host
	}
	proxy.ServeHTTP(rw, req)
}
