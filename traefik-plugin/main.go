package traefik_plugin

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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
	JobSpecKey    string `json:"jobSpecKey"`
}

func CreateConfig() *Config {
	return &Config{
		Timeout: "30s",
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
	jobName       string
	group         string
	service       string
	client        *http.Client

	// wakeupLocks prevents multiple concurrent scale-ups for the same service
	wakeupLocks sync.Map // map[string]*wakeupState
}

// wakeupState tracks the wake-up state for a service using a simple mutex
type wakeupState struct {
	mu sync.Mutex
}

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
	Status string `json:"Status"`
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

	client := &http.Client{Timeout: 10 * time.Second}

	nomadAddr := coalesce(config.NomadAddr, os.Getenv("S2Z_NOMAD_ADDR"), "http://nomad.service.consul:4646")
	consulAddr := coalesce(config.ConsulAddr, os.Getenv("S2Z_CONSUL_ADDR"), "http://consul.service.consul:8500")
	redisAddr := coalesce(config.RedisAddr, os.Getenv("S2Z_REDIS_ADDR"))
	redisPass := coalesce(config.RedisPassword, os.Getenv("S2Z_REDIS_PASSWORD"))
	nomadToken := coalesce(config.NomadToken, os.Getenv("S2Z_NOMAD_TOKEN"))
	consulToken := coalesce(config.ConsulToken, os.Getenv("S2Z_CONSUL_TOKEN"))
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
		jobName:       config.JobName,
		group:         config.GroupName,
		service:       config.ServiceName,
		client:        client,
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

func (s *ScaleWaker) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	ctx := req.Context()
	service, job, group := s.resolveTarget(req)
	if service == "" || job == "" || group == "" {
		http.Error(rw, "missing service mapping", http.StatusServiceUnavailable)
		return
	}

	endpoint, healthy, err := s.getHealthyEndpoint(ctx, service)
	if err != nil {
		http.Error(rw, fmt.Sprintf("health check: %v", err), http.StatusServiceUnavailable)
		return
	}

	// If Consul says healthy, verify endpoint is actually reachable
	// (handles stale/orphaned Consul catalog entries)
	if healthy {
		if !s.isEndpointReachable(endpoint) {
			healthy = false
		}
	}

	if !healthy {
		// Use per-service lock to prevent concurrent wake-ups
		endpoint, err = s.wakeUpService(ctx, service, job, group)
		if err != nil {
			http.Error(rw, fmt.Sprintf("wake up: %v", err), http.StatusServiceUnavailable)
			return
		}
	}

	if err := s.recordActivity(ctx, service); err != nil {
		http.Error(rw, fmt.Sprintf("activity store: %v", err), http.StatusServiceUnavailable)
		return
	}

	s.proxyTo(rw, req, endpoint)
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

	// Check if service became healthy AND is actually reachable
	endpoint, healthy, err := s.getHealthyEndpoint(ctx, service)
	if err != nil {
		return nil, err
	}
	if healthy && s.isEndpointReachable(endpoint) {
		return endpoint, nil
	}

	// We're the one doing the wake-up
	if err := s.ensureJob(ctx, job); err != nil {
		return nil, fmt.Errorf("ensure job: %w", err)
	}
	if err := s.scaleUp(ctx, job, group); err != nil {
		// If scaling fails, still wait for the service to become healthy
		// (e.g., another deployment is already in progress).
		endpoint, waitErr := s.waitForHealthy(ctx, service)
		if waitErr == nil {
			return endpoint, nil
		}
		return nil, fmt.Errorf("scale up: %w", err)
	}

	endpoint, err = s.waitForHealthy(ctx, service)
	if err != nil {
		return nil, fmt.Errorf("wait healthy: %w", err)
	}

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
	// Debug: log which store we're using
	fmt.Printf("[scalewaker] getJobSpec: store=%s, redisAddr=%s, key=%s\n", s.jobSpecStore, s.redisAddr, key)

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

// getRedisValue retrieves a value from Redis using simple RESP protocol
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
		authCmd := fmt.Sprintf("*2\r\n$4\r\nAUTH\r\n$%d\r\n%s\r\n", len(s.redisPass), s.redisPass)
		if _, err := conn.Write([]byte(authCmd)); err != nil {
			return nil, fmt.Errorf("redis auth write: %w", err)
		}
		authResp := make([]byte, 128)
		n, err := conn.Read(authResp)
		if err != nil {
			return nil, fmt.Errorf("redis auth read: %w", err)
		}
		if !strings.HasPrefix(string(authResp[:n]), "+OK") {
			return nil, fmt.Errorf("redis auth failed: %s", string(authResp[:n]))
		}
	}

	// GET command in RESP format
	getCmd := fmt.Sprintf("*2\r\n$3\r\nGET\r\n$%d\r\n%s\r\n", len(key), key)
	if _, err := conn.Write([]byte(getCmd)); err != nil {
		return nil, fmt.Errorf("redis get write: %w", err)
	}

	// Read response
	buf := make([]byte, 64*1024) // 64KB buffer for job specs
	n, err := conn.Read(buf)
	if err != nil {
		return nil, fmt.Errorf("redis get read: %w", err)
	}

	resp := string(buf[:n])

	// Parse RESP response
	if strings.HasPrefix(resp, "$-1") {
		return nil, fmt.Errorf("job spec not found at %s", key)
	}
	if strings.HasPrefix(resp, "-") {
		return nil, fmt.Errorf("redis error: %s", strings.TrimSpace(resp[1:]))
	}
	if strings.HasPrefix(resp, "$") {
		// Bulk string: $<length>\r\n<data>\r\n
		idx := strings.Index(resp, "\r\n")
		if idx == -1 {
			return nil, fmt.Errorf("invalid redis response")
		}
		dataStart := idx + 2
		dataEnd := strings.LastIndex(resp, "\r\n")
		if dataEnd <= dataStart {
			dataEnd = len(resp)
		}
		return []byte(resp[dataStart:dataEnd]), nil
	}

	return nil, fmt.Errorf("unexpected redis response: %s", resp[:min(50, len(resp))])
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
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
			return nil, fmt.Errorf("timeout waiting for service %s", service)
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
		authCmd := fmt.Sprintf("*2\r\n$4\r\nAUTH\r\n$%d\r\n%s\r\n", len(s.redisPass), s.redisPass)
		if _, err := conn.Write([]byte(authCmd)); err != nil {
			return fmt.Errorf("redis auth write: %w", err)
		}
		authResp := make([]byte, 128)
		n, err := conn.Read(authResp)
		if err != nil {
			return fmt.Errorf("redis auth read: %w", err)
		}
		if !strings.HasPrefix(string(authResp[:n]), "+OK") {
			return fmt.Errorf("redis auth failed: %s", string(authResp[:n]))
		}
	}

	setCmd := fmt.Sprintf("*3\r\n$3\r\nSET\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n", len(key), key, len(value), value)
	if _, err := conn.Write([]byte(setCmd)); err != nil {
		return fmt.Errorf("redis set write: %w", err)
	}

	resp := make([]byte, 128)
	n, err := conn.Read(resp)
	if err != nil {
		return fmt.Errorf("redis set read: %w", err)
	}
	if !strings.HasPrefix(string(resp[:n]), "+OK") {
		return fmt.Errorf("redis set failed: %s", strings.TrimSpace(string(resp[:n])))
	}

	return nil
}

func (s *ScaleWaker) proxyTo(rw http.ResponseWriter, req *http.Request, target *url.URL) {
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(rw http.ResponseWriter, req *http.Request, err error) {
		http.Error(rw, fmt.Sprintf("proxy error: %v", err), http.StatusBadGateway)
	}
	proxy.Director = func(r *http.Request) {
		r.URL.Scheme = target.Scheme
		r.URL.Host = target.Host
		r.Host = target.Host
	}
	proxy.ServeHTTP(rw, req)
}
