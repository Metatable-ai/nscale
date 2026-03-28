//go:build !integration

// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0

package traefik_plugin

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// Unit tests — no infrastructure required
// ---------------------------------------------------------------------------

func TestCoalesce(t *testing.T) {
	tests := []struct {
		name   string
		values []string
		want   string
	}{
		{"first non-empty wins", []string{"a", "b"}, "a"},
		{"skip empty", []string{"", "b", "c"}, "b"},
		{"skip whitespace", []string{"  ", "b"}, "b"},
		{"all empty", []string{"", "", ""}, ""},
		{"single value", []string{"x"}, "x"},
		{"no values", nil, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := coalesce(tt.values...)
			if got != tt.want {
				t.Errorf("coalesce(%v) = %q, want %q", tt.values, got, tt.want)
			}
		})
	}
}

func TestWrapJobRegister(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		wantErr bool
		check   func(t *testing.T, result []byte)
	}{
		{
			name:  "unwrapped job with Stop=true",
			input: `{"ID":"test","Name":"test","Stop":true}`,
			check: func(t *testing.T, result []byte) {
				var w struct {
					Job map[string]interface{} `json:"Job"`
				}
				if err := json.Unmarshal(result, &w); err != nil {
					t.Fatal(err)
				}
				if w.Job == nil {
					t.Fatal("expected Job wrapper")
				}
				if w.Job["Stop"] != false {
					t.Errorf("Stop = %v, want false", w.Job["Stop"])
				}
			},
		},
		{
			name:  "already wrapped",
			input: `{"Job":{"ID":"test","Stop":true}}`,
			check: func(t *testing.T, result []byte) {
				var w struct {
					Job map[string]interface{} `json:"Job"`
				}
				if err := json.Unmarshal(result, &w); err != nil {
					t.Fatal(err)
				}
				if w.Job["Stop"] != false {
					t.Errorf("Stop = %v, want false", w.Job["Stop"])
				}
			},
		},
		{
			name:  "unwrapped without Stop field",
			input: `{"ID":"test","Name":"test"}`,
			check: func(t *testing.T, result []byte) {
				var w struct {
					Job map[string]interface{} `json:"Job"`
				}
				if err := json.Unmarshal(result, &w); err != nil {
					t.Fatal(err)
				}
				if w.Job["Stop"] != false {
					t.Errorf("Stop = %v, want false", w.Job["Stop"])
				}
			},
		},
		{
			name:    "invalid JSON",
			input:   `not json`,
			wantErr: true,
		},
		{
			name:    "empty input",
			input:   ``,
			wantErr: true,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := wrapJobRegister([]byte(tt.input))
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.check != nil {
				tt.check(t, result)
			}
		})
	}
}

func TestResolveTarget(t *testing.T) {
	tests := []struct {
		name    string
		sw      *ScaleWaker
		host    string
		wantSvc string
		wantJob string
		wantGrp string
	}{
		{
			name:    "explicit config",
			sw:      &ScaleWaker{service: "mysvc", jobName: "myjob", group: "mygrp"},
			host:    "whatever.localhost",
			wantSvc: "mysvc", wantJob: "myjob", wantGrp: "mygrp",
		},
		{
			name:    "derived from Host header",
			sw:      &ScaleWaker{},
			host:    "echo-s2z.localhost",
			wantSvc: "echo-s2z", wantJob: "echo-s2z", wantGrp: "main",
		},
		{
			name:    "host with port",
			sw:      &ScaleWaker{},
			host:    "echo-s2z.localhost:8080",
			wantSvc: "echo-s2z", wantJob: "echo-s2z", wantGrp: "main",
		},
		{
			name:    "service only in config",
			sw:      &ScaleWaker{service: "mysvc"},
			host:    "whatever",
			wantSvc: "mysvc", wantJob: "mysvc", wantGrp: "main",
		},
		{
			name:    "job defaults to service",
			sw:      &ScaleWaker{},
			host:    "app.localhost",
			wantSvc: "app", wantJob: "app", wantGrp: "main",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest("GET", "/", nil)
			req.Host = tt.host
			svc, job, grp := tt.sw.resolveTarget(req)
			if svc != tt.wantSvc {
				t.Errorf("service = %q, want %q", svc, tt.wantSvc)
			}
			if job != tt.wantJob {
				t.Errorf("job = %q, want %q", job, tt.wantJob)
			}
			if grp != tt.wantGrp {
				t.Errorf("group = %q, want %q", grp, tt.wantGrp)
			}
		})
	}
}

func TestJobSpecKey(t *testing.T) {
	tests := []struct {
		name      string
		configKey string
		job       string
		want      string
	}{
		{"default key", "", "echo-s2z", "scale-to-zero/jobs/echo-s2z"},
		{"custom key", "custom/path/job", "echo-s2z", "custom/path/job"},
		{"leading slash stripped", "", "/echo-s2z", "scale-to-zero/jobs/echo-s2z"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sw := &ScaleWaker{config: &Config{JobSpecKey: tt.configKey}}
			got := sw.jobSpecKey(tt.job)
			if got != tt.want {
				t.Errorf("jobSpecKey(%q) = %q, want %q", tt.job, got, tt.want)
			}
		})
	}
}

func TestIsEndpointReachable(t *testing.T) {
	sw := &ScaleWaker{}

	// nil URL
	if sw.isEndpointReachable(nil) {
		t.Error("nil URL should not be reachable")
	}

	// real listener
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	u, _ := url.Parse("http://" + ln.Addr().String())
	if !sw.isEndpointReachable(u) {
		t.Errorf("expected %s to be reachable", u)
	}

	// port that is almost certainly not listening
	u2, _ := url.Parse("http://127.0.0.1:1")
	if sw.isEndpointReachable(u2) {
		t.Error("port 1 should not be reachable")
	}
}

// ---------------------------------------------------------------------------
// Component tests — Nomad/Consul mocked via httptest
// ---------------------------------------------------------------------------

// backendInfo holds a running httptest backend and its parsed address.
type backendInfo struct {
	server  *httptest.Server
	host    string
	port    int
	entries []consulServiceEntry
}

func startBackend(t *testing.T, body string) *backendInfo {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte(body))
	}))
	u, _ := url.Parse(srv.URL)
	host, portStr, _ := net.SplitHostPort(u.Host)
	var port int
	fmt.Sscanf(portStr, "%d", &port)

	entries := []consulServiceEntry{{}}
	entries[0].Node.Address = host
	entries[0].Service.Address = host
	entries[0].Service.Port = port
	return &backendInfo{server: srv, host: host, port: port, entries: entries}
}

// makeAllocations creates a mock Nomad allocation response pointing at the backend.
// This returns a "full" allocation with Resources.Networks populated,
// as the individual /v1/allocation/:id endpoint would return.
func makeAllocations(group, host string, port int) []nomadAllocation {
	return []nomadAllocation{makeFullAllocation(group, host, port)}
}

// makeFullAllocation creates a single allocation with network info populated.
func makeFullAllocation(group, host string, port int) nomadAllocation {
	return nomadAllocation{
		ID:           "alloc-test-12345678",
		TaskGroup:    group,
		ClientStatus: "running",
		TaskStates: map[string]struct {
			State string `json:"State"`
		}{
			"server": {State: "running"},
		},
		Resources: struct {
			Networks []nomadAllocNetwork `json:"Networks"`
		}{
			Networks: []nomadAllocNetwork{{
				IP:           host,
				DynamicPorts: []nomadAllocDynPort{{Label: "http", Value: port}},
			}},
		},
	}
}

// makeAllocStubs creates allocation stubs without network info,
// as the list endpoint /v1/job/:id/allocations returns in real Nomad.
func makeAllocStubs(group string) []nomadAllocation {
	return []nomadAllocation{{
		ID:           "alloc-test-12345678",
		TaskGroup:    group,
		ClientStatus: "running",
		TaskStates: map[string]struct {
			State string `json:"State"`
		}{
			"server": {State: "running"},
		},
	}}
}

func TestServeHTTP_HealthyService(t *testing.T) {
	be := startBackend(t, "backend OK")
	defer be.server.Close()

	activityRecorded := false

	consul := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/health/service/"):
			w.Header().Set("X-Consul-Index", "1")
			json.NewEncoder(w).Encode(be.entries)
		case strings.HasPrefix(r.URL.Path, "/v1/kv/"):
			if r.Method == http.MethodPut {
				activityRecorded = true
				w.Write([]byte("true"))
				return
			}
			w.WriteHeader(http.StatusNotFound)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer consul.Close()

	sw := &ScaleWaker{
		next:          http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Fatal("next called") }),
		config:        &Config{ServiceName: "test-svc", JobName: "test-job", GroupName: "main"},
		service:       "test-svc",
		jobName:       "test-job",
		group:         "main",
		consulAddr:    consul.URL,
		nomadAddr:     "http://unused",
		activityStore: "consul",
		client:        &http.Client{Timeout: 5 * time.Second},
		timeout:       30 * time.Second,
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/hello", nil)
	req.Host = "test-svc.localhost"
	sw.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200; body: %s", rec.Code, rec.Body.String())
	}
	if rec.Body.String() != "backend OK" {
		t.Errorf("body = %q, want %q", rec.Body.String(), "backend OK")
	}
	if !activityRecorded {
		t.Error("activity was not recorded")
	}
}

func TestServeHTTP_WakeUpFromZero(t *testing.T) {
	be := startBackend(t, "woke up")
	defer be.server.Close()

	var scaled int32 // flips to 1 after scaleUp
	scaleUpCalled := false
	jobRegistered := false

	consul := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/health/service/"):
			w.Header().Set("X-Consul-Index", "1")
			if atomic.LoadInt32(&scaled) == 1 {
				json.NewEncoder(w).Encode(be.entries)
			} else {
				json.NewEncoder(w).Encode([]consulServiceEntry{})
			}
		case strings.HasPrefix(r.URL.Path, "/v1/kv/"):
			if r.Method == http.MethodPut {
				w.Write([]byte("true"))
				return
			}
			// GET — return job spec
			w.Write([]byte(`{"ID":"test-job","Name":"test-job","Type":"service"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer consul.Close()

	nomad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/scale") && r.Method == http.MethodPost:
			scaleUpCalled = true
			atomic.StoreInt32(&scaled, 1)
			w.Write([]byte(`{}`))
		case strings.HasSuffix(r.URL.Path, "/allocations") && r.Method == http.MethodGet:
			if atomic.LoadInt32(&scaled) == 1 {
				json.NewEncoder(w).Encode(makeAllocStubs("main"))
			} else {
				json.NewEncoder(w).Encode([]nomadAllocation{})
			}
		case strings.HasPrefix(r.URL.Path, "/v1/allocation/") && r.Method == http.MethodGet:
			json.NewEncoder(w).Encode(makeFullAllocation("main", be.host, be.port))
		case r.URL.Path == "/v1/jobs" && r.Method == http.MethodPost:
			jobRegistered = true
			w.Write([]byte(`{}`))
		case strings.HasPrefix(r.URL.Path, "/v1/job/"):
			count := 0
			if atomic.LoadInt32(&scaled) == 1 {
				count = 1
			}
			json.NewEncoder(w).Encode(nomadJobInfo{
				Status:     "dead",
				TaskGroups: []nomadJobTaskGroup{{Name: "main", Count: count}},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer nomad.Close()

	sw := &ScaleWaker{
		next:          http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Fatal("next called") }),
		config:        &Config{ServiceName: "test-svc", JobName: "test-job", GroupName: "main"},
		service:       "test-svc",
		jobName:       "test-job",
		group:         "main",
		consulAddr:    consul.URL,
		nomadAddr:     nomad.URL,
		activityStore: "consul",
		jobSpecStore:  "consul",
		client:        &http.Client{Timeout: 5 * time.Second},
		timeout:       10 * time.Second,
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/", nil)
	req.Host = "test-svc.localhost"
	sw.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body: %s", rec.Code, rec.Body.String())
	}
	if !jobRegistered {
		t.Error("job was not registered via POST /v1/jobs")
	}
	if !scaleUpCalled {
		t.Error("scale-up was not called")
	}
}

func TestServeHTTP_ConcurrentWakeupDedup(t *testing.T) {
	be := startBackend(t, "OK")
	defer be.server.Close()

	var scaled int32
	var scaleCount int32

	consul := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/health/service/"):
			w.Header().Set("X-Consul-Index", "1")
			if atomic.LoadInt32(&scaled) == 1 {
				json.NewEncoder(w).Encode(be.entries)
			} else {
				json.NewEncoder(w).Encode([]consulServiceEntry{})
			}
		case strings.HasPrefix(r.URL.Path, "/v1/kv/"):
			if r.Method == http.MethodPut {
				w.Write([]byte("true"))
				return
			}
			w.Write([]byte(`{"ID":"test-job","Name":"test-job"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer consul.Close()

	nomad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/scale") && r.Method == http.MethodPost:
			atomic.AddInt32(&scaleCount, 1)
			atomic.StoreInt32(&scaled, 1)
			w.Write([]byte(`{}`))
		case strings.HasSuffix(r.URL.Path, "/allocations") && r.Method == http.MethodGet:
			if atomic.LoadInt32(&scaled) == 1 {
				json.NewEncoder(w).Encode(makeAllocStubs("main"))
			} else {
				json.NewEncoder(w).Encode([]nomadAllocation{})
			}
		case strings.HasPrefix(r.URL.Path, "/v1/allocation/") && r.Method == http.MethodGet:
			json.NewEncoder(w).Encode(makeFullAllocation("main", be.host, be.port))
		case r.URL.Path == "/v1/jobs" && r.Method == http.MethodPost:
			w.Write([]byte(`{}`))
		case strings.HasPrefix(r.URL.Path, "/v1/job/"):
			count := 0
			if atomic.LoadInt32(&scaled) == 1 {
				count = 1
			}
			json.NewEncoder(w).Encode(nomadJobInfo{
				Status:     "dead",
				TaskGroups: []nomadJobTaskGroup{{Name: "main", Count: count}},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer nomad.Close()

	sw := &ScaleWaker{
		next:          http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}),
		config:        &Config{ServiceName: "test-svc", JobName: "test-job", GroupName: "main"},
		service:       "test-svc",
		jobName:       "test-job",
		group:         "main",
		consulAddr:    consul.URL,
		nomadAddr:     nomad.URL,
		activityStore: "consul",
		jobSpecStore:  "consul",
		client:        &http.Client{Timeout: 5 * time.Second},
		timeout:       10 * time.Second,
	}

	const n = 10
	var wg sync.WaitGroup
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func() {
			defer wg.Done()
			rec := httptest.NewRecorder()
			r := httptest.NewRequest("GET", "/", nil)
			r.Host = "test-svc.localhost"
			sw.ServeHTTP(rec, r)
		}()
	}
	wg.Wait()

	c := atomic.LoadInt32(&scaleCount)
	if c != 1 {
		t.Errorf("scale-up called %d times, want exactly 1 (dedup via mutex)", c)
	}
}

func TestServeHTTP_MissingServiceMapping(t *testing.T) {
	sw := &ScaleWaker{
		next:          http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}),
		config:        &Config{},
		consulAddr:    "http://unused",
		nomadAddr:     "http://unused",
		activityStore: "consul",
		client:        &http.Client{Timeout: 5 * time.Second},
		timeout:       30 * time.Second,
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/", nil)
	req.Host = "" // empty host → empty service
	sw.ServeHTTP(rec, req)

	// resolveTarget with empty host yields service="" → 503
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503", rec.Code)
	}
}

func TestServeHTTP_Timeout(t *testing.T) {
	// Consul never returns healthy entries → should time out.
	consul := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/health/service/"):
			// Simulate blocking query delay to prevent tight loop
			if r.URL.Query().Get("wait") != "" {
				time.Sleep(200 * time.Millisecond)
			}
			w.Header().Set("X-Consul-Index", "1")
			json.NewEncoder(w).Encode([]consulServiceEntry{})
		case strings.HasPrefix(r.URL.Path, "/v1/kv/"):
			if r.Method == http.MethodGet {
				w.Write([]byte(`{"ID":"timeout-job","Name":"timeout-job"}`))
				return
			}
			w.Write([]byte("true"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer consul.Close()

	nomad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/scale") && r.Method == http.MethodPost:
			w.Write([]byte(`{}`))
		case strings.HasSuffix(r.URL.Path, "/allocations") && r.Method == http.MethodGet:
			json.NewEncoder(w).Encode([]nomadAllocation{})
		case r.URL.Path == "/v1/jobs" && r.Method == http.MethodPost:
			w.Write([]byte(`{}`))
		case strings.HasPrefix(r.URL.Path, "/v1/job/"):
			json.NewEncoder(w).Encode(nomadJobInfo{
				Status:     "dead",
				TaskGroups: []nomadJobTaskGroup{{Name: "main", Count: 0}},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer nomad.Close()

	sw := &ScaleWaker{
		next:          http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}),
		config:        &Config{ServiceName: "to-svc", JobName: "to-job", GroupName: "main"},
		service:       "to-svc",
		jobName:       "to-job",
		group:         "main",
		consulAddr:    consul.URL,
		nomadAddr:     nomad.URL,
		activityStore: "consul",
		jobSpecStore:  "consul",
		client:        &http.Client{Timeout: 5 * time.Second},
		timeout:       1 * time.Second,
	}

	start := time.Now()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/", nil)
	req.Host = "to-svc.localhost"
	sw.ServeHTTP(rec, req)
	elapsed := time.Since(start)

	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503", rec.Code)
	}
	if elapsed > 5*time.Second {
		t.Errorf("took %v, expected ~1 s", elapsed)
	}
}

func TestServeHTTP_StaleConsulEntry(t *testing.T) {
	// Consul reports healthy but the endpoint is unreachable.
	// ScaleWaker should detect stale entry and trigger wake-up.
	be := startBackend(t, "fresh")
	defer be.server.Close()

	var wakeupDone int32

	// Stale entry pointing to unreachable port
	staleEntries := []consulServiceEntry{{}}
	staleEntries[0].Node.Address = "127.0.0.1"
	staleEntries[0].Service.Address = "127.0.0.1"
	staleEntries[0].Service.Port = 1 // unreachable

	consul := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/health/service/"):
			w.Header().Set("X-Consul-Index", "1")
			if atomic.LoadInt32(&wakeupDone) == 1 {
				json.NewEncoder(w).Encode(be.entries)
			} else {
				// Return stale entry (unreachable endpoint)
				json.NewEncoder(w).Encode(staleEntries)
			}
		case strings.HasPrefix(r.URL.Path, "/v1/kv/"):
			if r.Method == http.MethodPut {
				w.Write([]byte("true"))
				return
			}
			w.Write([]byte(`{"ID":"stale-job","Name":"stale-job"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer consul.Close()

	nomad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/scale") && r.Method == http.MethodPost:
			atomic.StoreInt32(&wakeupDone, 1)
			w.Write([]byte(`{}`))
		case strings.HasSuffix(r.URL.Path, "/allocations") && r.Method == http.MethodGet:
			if atomic.LoadInt32(&wakeupDone) == 1 {
				json.NewEncoder(w).Encode(makeAllocStubs("main"))
			} else {
				json.NewEncoder(w).Encode([]nomadAllocation{})
			}
		case strings.HasPrefix(r.URL.Path, "/v1/allocation/") && r.Method == http.MethodGet:
			json.NewEncoder(w).Encode(makeFullAllocation("main", be.host, be.port))
		case r.URL.Path == "/v1/jobs" && r.Method == http.MethodPost:
			w.Write([]byte(`{}`))
		case strings.HasPrefix(r.URL.Path, "/v1/job/"):
			count := 0
			if atomic.LoadInt32(&wakeupDone) == 1 {
				count = 1
			}
			json.NewEncoder(w).Encode(nomadJobInfo{
				Status:     "running",
				TaskGroups: []nomadJobTaskGroup{{Name: "main", Count: count}},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer nomad.Close()

	sw := &ScaleWaker{
		next:          http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}),
		config:        &Config{ServiceName: "stale-svc", JobName: "stale-job", GroupName: "main"},
		service:       "stale-svc",
		jobName:       "stale-job",
		group:         "main",
		consulAddr:    consul.URL,
		nomadAddr:     nomad.URL,
		activityStore: "consul",
		jobSpecStore:  "consul",
		client:        &http.Client{Timeout: 5 * time.Second},
		timeout:       10 * time.Second,
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/", nil)
	req.Host = "stale-svc.localhost"
	sw.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200; body: %s", rec.Code, rec.Body.String())
	}
}

func TestNew_Defaults(t *testing.T) {
	cfg := CreateConfig()
	h, err := New(context.Background(), http.NotFoundHandler(), cfg, "test")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	sw := h.(*ScaleWaker)

	if sw.timeout != 30*time.Second {
		t.Errorf("timeout = %v, want 30s", sw.timeout)
	}
	if sw.probePath != "/healthz" {
		t.Errorf("probePath = %q, want /healthz", sw.probePath)
	}
	if sw.activityStore != "consul" {
		t.Errorf("activityStore = %q, want consul", sw.activityStore)
	}
	if sw.jobSpecStore != "consul" {
		t.Errorf("jobSpecStore = %q, want consul", sw.jobSpecStore)
	}
}

func TestNew_InvalidTimeout(t *testing.T) {
	cfg := &Config{Timeout: "notaduration"}
	_, err := New(context.Background(), http.NotFoundHandler(), cfg, "test")
	if err == nil {
		t.Fatal("expected error for invalid timeout")
	}
}

// ---------------------------------------------------------------------------
// Stress tests
// ---------------------------------------------------------------------------

func TestStress_ServeHTTP_Burst(t *testing.T) {
	be := startBackend(t, "OK")
	defer be.server.Close()

	var scaled int32

	consul := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/health/service/"):
			w.Header().Set("X-Consul-Index", "1")
			if atomic.LoadInt32(&scaled) == 1 {
				json.NewEncoder(w).Encode(be.entries)
			} else {
				json.NewEncoder(w).Encode([]consulServiceEntry{})
			}
		case strings.HasPrefix(r.URL.Path, "/v1/kv/"):
			if r.Method == http.MethodPut {
				w.Write([]byte("true"))
				return
			}
			w.Write([]byte(`{"ID":"burst-job","Name":"burst-job"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer consul.Close()

	var scaleCount atomic.Int32

	nomad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/scale") && r.Method == http.MethodPost:
			scaleCount.Add(1)
			atomic.StoreInt32(&scaled, 1)
			w.Write([]byte(`{}`))
		case strings.HasSuffix(r.URL.Path, "/allocations") && r.Method == http.MethodGet:
			if atomic.LoadInt32(&scaled) == 1 {
				json.NewEncoder(w).Encode(makeAllocStubs("main"))
			} else {
				json.NewEncoder(w).Encode([]nomadAllocation{})
			}
		case strings.HasPrefix(r.URL.Path, "/v1/allocation/") && r.Method == http.MethodGet:
			json.NewEncoder(w).Encode(makeFullAllocation("main", be.host, be.port))
		case r.URL.Path == "/v1/jobs" && r.Method == http.MethodPost:
			w.Write([]byte(`{}`))
		case strings.HasPrefix(r.URL.Path, "/v1/job/"):
			count := 0
			if atomic.LoadInt32(&scaled) == 1 {
				count = 1
			}
			json.NewEncoder(w).Encode(nomadJobInfo{
				Status:     "dead",
				TaskGroups: []nomadJobTaskGroup{{Name: "main", Count: count}},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer nomad.Close()

	sw := &ScaleWaker{
		next:          http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}),
		config:        &Config{ServiceName: "burst-svc", JobName: "burst-job", GroupName: "main"},
		service:       "burst-svc",
		jobName:       "burst-job",
		group:         "main",
		consulAddr:    consul.URL,
		nomadAddr:     nomad.URL,
		activityStore: "consul",
		jobSpecStore:  "consul",
		client:        &http.Client{Timeout: 5 * time.Second},
		timeout:       10 * time.Second,
	}

	// Burst: 100 concurrent requests
	const n = 100
	var wg sync.WaitGroup
	var okCount, errCount atomic.Int32

	wg.Add(n)
	for i := 0; i < n; i++ {
		go func() {
			defer wg.Done()
			rec := httptest.NewRecorder()
			r := httptest.NewRequest("GET", "/", nil)
			r.Host = "burst-svc.localhost"
			sw.ServeHTTP(rec, r)
			if rec.Code == http.StatusOK {
				okCount.Add(1)
			} else {
				errCount.Add(1)
			}
		}()
	}
	wg.Wait()

	t.Logf("burst: ok=%d err=%d scaleUps=%d", okCount.Load(), errCount.Load(), scaleCount.Load())
	if sc := scaleCount.Load(); sc != 1 {
		t.Errorf("scale-up called %d times, want exactly 1", sc)
	}
	if oc := okCount.Load(); oc < int32(n/2) {
		t.Errorf("fewer than 50%% requests succeeded: %d / %d", oc, n)
	}
}

func TestStress_ServeHTTP_ActivityNonBlocking(t *testing.T) {
	// Activity store returns errors but requests should still succeed
	be := startBackend(t, "still works")
	defer be.server.Close()

	consul := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/health/service/"):
			w.Header().Set("X-Consul-Index", "1")
			json.NewEncoder(w).Encode(be.entries)
		case strings.HasPrefix(r.URL.Path, "/v1/kv/"):
			if r.Method == http.MethodPut {
				// Simulate activity store failure
				w.WriteHeader(http.StatusInternalServerError)
				w.Write([]byte("store error"))
				return
			}
			w.WriteHeader(http.StatusNotFound)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer consul.Close()

	sw := &ScaleWaker{
		next:          http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Fatal("next called") }),
		config:        &Config{ServiceName: "nb-svc", JobName: "nb-job", GroupName: "main"},
		service:       "nb-svc",
		jobName:       "nb-job",
		group:         "main",
		consulAddr:    consul.URL,
		nomadAddr:     "http://unused",
		activityStore: "consul",
		client:        &http.Client{Timeout: 5 * time.Second},
		timeout:       30 * time.Second,
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/hello", nil)
	req.Host = "nb-svc.localhost"
	sw.ServeHTTP(rec, req)

	// Should still succeed despite activity store error
	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200 (activity recording is non-blocking); body: %s",
			rec.Code, rec.Body.String())
	}
}

// ---------------------------------------------------------------------------
// Architecture fix tests
// ---------------------------------------------------------------------------

func TestServeHTTP_EndpointCache_HitOnSecondRequest(t *testing.T) {
	// Backend that responds to both normal requests and /healthz probe
	be := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("ok"))
			return
		}
		w.Write([]byte("cached OK"))
	}))
	defer be.Close()

	u, _ := url.Parse(be.URL)
	host, portStr, _ := net.SplitHostPort(u.Host)
	var port int
	fmt.Sscanf(portStr, "%d", &port)

	entries := []consulServiceEntry{{}}
	entries[0].Node.Address = host
	entries[0].Service.Address = host
	entries[0].Service.Port = port

	var consulHealthCalls atomic.Int32

	consul := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/health/service/"):
			consulHealthCalls.Add(1)
			w.Header().Set("X-Consul-Index", "1")
			json.NewEncoder(w).Encode(entries)
		case strings.HasPrefix(r.URL.Path, "/v1/kv/"):
			if r.Method == http.MethodPut {
				w.Write([]byte("true"))
				return
			}
			w.WriteHeader(http.StatusNotFound)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer consul.Close()

	nomad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/job/"):
			json.NewEncoder(w).Encode(nomadJobInfo{
				Status:     "running",
				TaskGroups: []nomadJobTaskGroup{{Name: "main", Count: 1}},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer nomad.Close()

	sw := &ScaleWaker{
		next:          http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Fatal("next called") }),
		config:        &Config{ServiceName: "cache-svc", JobName: "cache-job", GroupName: "main"},
		service:       "cache-svc",
		jobName:       "cache-job",
		group:         "main",
		consulAddr:    consul.URL,
		nomadAddr:     nomad.URL,
		activityStore: "consul",
		jobSpecStore:  "consul",
		client:        &http.Client{Timeout: 5 * time.Second},
		timeout:       10 * time.Second,
		logger:        newPluginLogger("test"),
		observability: defaultWakeObservabilityInstance(),
	}

	// First request — populates cache via Consul
	rec1 := httptest.NewRecorder()
	req1 := httptest.NewRequest("GET", "/hello", nil)
	req1.Host = "cache-svc.localhost"
	sw.ServeHTTP(rec1, req1)

	if rec1.Code != http.StatusOK {
		t.Fatalf("first request: status = %d, want 200; body: %s", rec1.Code, rec1.Body.String())
	}

	countAfterFirst := consulHealthCalls.Load()
	if countAfterFirst == 0 {
		t.Fatal("first request should have called Consul health endpoint")
	}

	// Second request — should be served from endpoint cache (no additional Consul health call)
	rec2 := httptest.NewRecorder()
	req2 := httptest.NewRequest("GET", "/hello", nil)
	req2.Host = "cache-svc.localhost"
	sw.ServeHTTP(rec2, req2)

	if rec2.Code != http.StatusOK {
		t.Fatalf("second request: status = %d, want 200; body: %s", rec2.Code, rec2.Body.String())
	}

	countAfterSecond := consulHealthCalls.Load()
	if countAfterSecond != countAfterFirst {
		t.Errorf("consul health calls: after first=%d, after second=%d; expected no additional call (cache hit)",
			countAfterFirst, countAfterSecond)
	}
}

func TestServeHTTP_EndpointCache_InvalidateOnUnreachable(t *testing.T) {
	// First backend — will be closed after first request to simulate unreachable
	be1 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("ok"))
			return
		}
		w.Write([]byte("first backend"))
	}))

	u1, _ := url.Parse(be1.URL)
	host1, portStr1, _ := net.SplitHostPort(u1.Host)
	var port1 int
	fmt.Sscanf(portStr1, "%d", &port1)

	entries1 := []consulServiceEntry{{}}
	entries1[0].Node.Address = host1
	entries1[0].Service.Address = host1
	entries1[0].Service.Port = port1

	// Second backend — takes over after be1 goes down
	be2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("ok"))
			return
		}
		w.Write([]byte("second backend"))
	}))
	defer be2.Close()

	u2, _ := url.Parse(be2.URL)
	host2, portStr2, _ := net.SplitHostPort(u2.Host)
	var port2 int
	fmt.Sscanf(portStr2, "%d", &port2)

	entries2 := []consulServiceEntry{{}}
	entries2[0].Node.Address = host2
	entries2[0].Service.Address = host2
	entries2[0].Service.Port = port2

	var be1Closed atomic.Int32

	consul := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/health/service/"):
			w.Header().Set("X-Consul-Index", "1")
			if be1Closed.Load() == 1 {
				json.NewEncoder(w).Encode(entries2)
			} else {
				json.NewEncoder(w).Encode(entries1)
			}
		case strings.HasPrefix(r.URL.Path, "/v1/kv/"):
			if r.Method == http.MethodPut {
				w.Write([]byte("true"))
				return
			}
			w.WriteHeader(http.StatusNotFound)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer consul.Close()

	nomad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/job/"):
			json.NewEncoder(w).Encode(nomadJobInfo{
				Status:     "running",
				TaskGroups: []nomadJobTaskGroup{{Name: "main", Count: 1}},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer nomad.Close()

	sw := &ScaleWaker{
		next:          http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Fatal("next called") }),
		config:        &Config{ServiceName: "inval-svc", JobName: "inval-job", GroupName: "main"},
		service:       "inval-svc",
		jobName:       "inval-job",
		group:         "main",
		consulAddr:    consul.URL,
		nomadAddr:     nomad.URL,
		activityStore: "consul",
		jobSpecStore:  "consul",
		client:        &http.Client{Timeout: 5 * time.Second},
		timeout:       10 * time.Second,
		logger:        newPluginLogger("test"),
		observability: defaultWakeObservabilityInstance(),
	}

	// First request — caches be1 endpoint
	rec1 := httptest.NewRecorder()
	req1 := httptest.NewRequest("GET", "/", nil)
	req1.Host = "inval-svc.localhost"
	sw.ServeHTTP(rec1, req1)

	if rec1.Code != http.StatusOK {
		t.Fatalf("first request: status = %d, want 200", rec1.Code)
	}
	if rec1.Body.String() != "first backend" {
		t.Fatalf("first request: body = %q, want %q", rec1.Body.String(), "first backend")
	}

	// Close first backend → cached endpoint becomes unreachable
	be1.Close()
	be1Closed.Store(1)

	// Second request — cache probe fails → invalidate → fall through to Consul → get be2
	rec2 := httptest.NewRecorder()
	req2 := httptest.NewRequest("GET", "/", nil)
	req2.Host = "inval-svc.localhost"
	sw.ServeHTTP(rec2, req2)

	if rec2.Code != http.StatusOK {
		t.Fatalf("second request: status = %d, want 200; body: %s", rec2.Code, rec2.Body.String())
	}
	if rec2.Body.String() != "second backend" {
		t.Errorf("second request: body = %q, want %q (should have fallen through to new backend)",
			rec2.Body.String(), "second backend")
	}
}

func TestServeHTTP_NilEndpointAfterWake(t *testing.T) {
	// Consul returns no healthy entries → triggers wake path.
	// Nomad returns allocations but with NO network info → waitForNomadAllocation returns nil → 503.
	consul := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/health/service/"):
			if r.URL.Query().Get("wait") != "" {
				time.Sleep(100 * time.Millisecond)
			}
			w.Header().Set("X-Consul-Index", "1")
			json.NewEncoder(w).Encode([]consulServiceEntry{})
		case strings.HasPrefix(r.URL.Path, "/v1/kv/"):
			if r.Method == http.MethodPut {
				w.Write([]byte("true"))
				return
			}
			w.Write([]byte(`{"ID":"nil-job","Name":"nil-job"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer consul.Close()

	nomad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/scale") && r.Method == http.MethodPost:
			w.Write([]byte(`{}`))
		case strings.HasSuffix(r.URL.Path, "/allocations") && r.Method == http.MethodGet:
			// Return running allocation stubs with no network info
			json.NewEncoder(w).Encode(makeAllocStubs("main"))
		case strings.HasPrefix(r.URL.Path, "/v1/allocation/") && r.Method == http.MethodGet:
			// Full allocation also has NO network info
			json.NewEncoder(w).Encode(nomadAllocation{
				ID:           "alloc-nil-12345678",
				TaskGroup:    "main",
				ClientStatus: "running",
				TaskStates: map[string]struct {
					State string `json:"State"`
				}{
					"server": {State: "running"},
				},
				// Resources.Networks is empty — no endpoint extractable
			})
		case r.URL.Path == "/v1/jobs" && r.Method == http.MethodPost:
			w.Write([]byte(`{}`))
		case strings.HasPrefix(r.URL.Path, "/v1/job/"):
			json.NewEncoder(w).Encode(nomadJobInfo{
				Status:     "dead",
				TaskGroups: []nomadJobTaskGroup{{Name: "main", Count: 0}},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer nomad.Close()

	sw := &ScaleWaker{
		next:          http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}),
		config:        &Config{ServiceName: "nil-svc", JobName: "nil-job", GroupName: "main"},
		service:       "nil-svc",
		jobName:       "nil-job",
		group:         "main",
		consulAddr:    consul.URL,
		nomadAddr:     nomad.URL,
		activityStore: "consul",
		jobSpecStore:  "consul",
		client:        &http.Client{Timeout: 5 * time.Second},
		timeout:       1 * time.Second, // Short timeout for fast test
		logger:        newPluginLogger("test"),
		observability: defaultWakeObservabilityInstance(),
	}

	start := time.Now()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/", nil)
	req.Host = "nil-svc.localhost"
	sw.ServeHTTP(rec, req)
	elapsed := time.Since(start)

	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503 (nil endpoint after wake); body: %s", rec.Code, rec.Body.String())
	}
	if elapsed > 5*time.Second {
		t.Errorf("took %v, expected ~1s timeout", elapsed)
	}
}

func TestServeHTTP_ConsulErrorFallthrough(t *testing.T) {
	// Consul health returns 500, but Nomad-direct wake path should still succeed.
	be := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("ok"))
			return
		}
		w.Write([]byte("consul-error-ok"))
	}))
	defer be.Close()

	u, _ := url.Parse(be.URL)
	beHost, portStr, _ := net.SplitHostPort(u.Host)
	var bePort int
	fmt.Sscanf(portStr, "%d", &bePort)

	var scaled int32

	consul := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/health/service/"):
			// Consul health always fails with 500
			w.WriteHeader(http.StatusInternalServerError)
			w.Write([]byte("consul internal error"))
		case strings.HasPrefix(r.URL.Path, "/v1/kv/"):
			if r.Method == http.MethodPut {
				w.Write([]byte("true"))
				return
			}
			// GET job spec — this still works
			w.Write([]byte(`{"ID":"cerr-job","Name":"cerr-job"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer consul.Close()

	nomad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/scale") && r.Method == http.MethodPost:
			atomic.StoreInt32(&scaled, 1)
			w.Write([]byte(`{}`))
		case strings.HasSuffix(r.URL.Path, "/allocations") && r.Method == http.MethodGet:
			if atomic.LoadInt32(&scaled) == 1 {
				json.NewEncoder(w).Encode(makeAllocStubs("main"))
			} else {
				json.NewEncoder(w).Encode([]nomadAllocation{})
			}
		case strings.HasPrefix(r.URL.Path, "/v1/allocation/") && r.Method == http.MethodGet:
			json.NewEncoder(w).Encode(makeFullAllocation("main", beHost, bePort))
		case r.URL.Path == "/v1/jobs" && r.Method == http.MethodPost:
			w.Write([]byte(`{}`))
		case strings.HasPrefix(r.URL.Path, "/v1/job/"):
			count := 0
			if atomic.LoadInt32(&scaled) == 1 {
				count = 1
			}
			json.NewEncoder(w).Encode(nomadJobInfo{
				Status:     "dead",
				TaskGroups: []nomadJobTaskGroup{{Name: "main", Count: count}},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer nomad.Close()

	sw := &ScaleWaker{
		next:          http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}),
		config:        &Config{ServiceName: "cerr-svc", JobName: "cerr-job", GroupName: "main"},
		service:       "cerr-svc",
		jobName:       "cerr-job",
		group:         "main",
		consulAddr:    consul.URL,
		nomadAddr:     nomad.URL,
		activityStore: "consul",
		jobSpecStore:  "consul",
		client:        &http.Client{Timeout: 5 * time.Second},
		timeout:       10 * time.Second,
		logger:        newPluginLogger("test"),
		observability: defaultWakeObservabilityInstance(),
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/", nil)
	req.Host = "cerr-svc.localhost"
	sw.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200 (Consul error should fall through to Nomad wake); body: %s",
			rec.Code, rec.Body.String())
	}
	if rec.Body.String() != "consul-error-ok" {
		t.Errorf("body = %q, want %q", rec.Body.String(), "consul-error-ok")
	}
}

func TestProxyPreservesHostHeader(t *testing.T) {
	// Backend captures the incoming Host header.
	var capturedHost atomic.Value

	be := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedHost.Store(r.Host)
		w.Write([]byte("host-ok"))
	}))
	defer be.Close()

	u, _ := url.Parse(be.URL)
	beHost, portStr, _ := net.SplitHostPort(u.Host)
	var bePort int
	fmt.Sscanf(portStr, "%d", &bePort)

	entries := []consulServiceEntry{{}}
	entries[0].Node.Address = beHost
	entries[0].Service.Address = beHost
	entries[0].Service.Port = bePort

	consul := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/health/service/"):
			w.Header().Set("X-Consul-Index", "1")
			json.NewEncoder(w).Encode(entries)
		case strings.HasPrefix(r.URL.Path, "/v1/kv/"):
			if r.Method == http.MethodPut {
				w.Write([]byte("true"))
				return
			}
			w.WriteHeader(http.StatusNotFound)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer consul.Close()

	nomad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/job/"):
			json.NewEncoder(w).Encode(nomadJobInfo{
				Status:     "running",
				TaskGroups: []nomadJobTaskGroup{{Name: "main", Count: 1}},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer nomad.Close()

	sw := &ScaleWaker{
		next:          http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Fatal("next called") }),
		config:        &Config{ServiceName: "host-svc", JobName: "host-job", GroupName: "main"},
		service:       "host-svc",
		jobName:       "host-job",
		group:         "main",
		consulAddr:    consul.URL,
		nomadAddr:     nomad.URL,
		activityStore: "consul",
		jobSpecStore:  "consul",
		client:        &http.Client{Timeout: 5 * time.Second},
		timeout:       10 * time.Second,
		logger:        newPluginLogger("test"),
		observability: defaultWakeObservabilityInstance(),
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/api/data", nil)
	req.Host = "custom-service.example.com"
	sw.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body: %s", rec.Code, rec.Body.String())
	}

	got, ok := capturedHost.Load().(string)
	if !ok || got == "" {
		t.Fatal("backend did not capture Host header")
	}
	if got != "custom-service.example.com" {
		t.Errorf("backend received Host = %q, want %q", got, "custom-service.example.com")
	}
}

func TestWaitForNomadAllocation_AdaptiveBackoff(t *testing.T) {
	// Backend that serves /healthz for the probe check
	be := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	}))
	defer be.Close()

	u, _ := url.Parse(be.URL)
	beHost, portStr, _ := net.SplitHostPort(u.Host)
	var bePort int
	fmt.Sscanf(portStr, "%d", &bePort)

	var callCount atomic.Int32
	var callTimes []time.Time
	var mu sync.Mutex

	// Return empty allocations for first 6 calls, then return healthy allocation
	const emptyCallsBeforeHealthy = 6

	nomad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/allocations") && r.Method == http.MethodGet:
			n := callCount.Add(1)
			mu.Lock()
			callTimes = append(callTimes, time.Now())
			mu.Unlock()

			if int(n) <= emptyCallsBeforeHealthy {
				json.NewEncoder(w).Encode([]nomadAllocation{})
			} else {
				json.NewEncoder(w).Encode(makeAllocStubs("main"))
			}
		case strings.HasPrefix(r.URL.Path, "/v1/allocation/") && r.Method == http.MethodGet:
			json.NewEncoder(w).Encode(makeFullAllocation("main", beHost, bePort))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer nomad.Close()

	sw := &ScaleWaker{
		next:          http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}),
		config:        &Config{ServiceName: "backoff-svc", JobName: "backoff-job", GroupName: "main"},
		service:       "backoff-svc",
		jobName:       "backoff-job",
		group:         "main",
		nomadAddr:     nomad.URL,
		client:        &http.Client{Timeout: 5 * time.Second},
		timeout:       30 * time.Second,
		logger:        newPluginLogger("test"),
		observability: defaultWakeObservabilityInstance(),
	}

	endpoint, err := sw.waitForNomadAllocation(context.Background(), "backoff-job", "main")
	if err != nil {
		t.Fatalf("waitForNomadAllocation returned error: %v", err)
	}
	if endpoint == nil {
		t.Fatal("waitForNomadAllocation returned nil endpoint")
	}

	mu.Lock()
	times := make([]time.Time, len(callTimes))
	copy(times, callTimes)
	mu.Unlock()

	if len(times) < 3 {
		t.Fatalf("expected at least 3 allocation calls, got %d", len(times))
	}

	// Verify intervals increase with adaptive backoff.
	// First intervals (elapsed < 5s) should be ~500ms.
	// Later intervals (elapsed 5-15s) should be ~1000ms.
	t.Logf("allocation call timestamps (%d calls):", len(times))
	for i := 1; i < len(times); i++ {
		interval := times[i].Sub(times[i-1])
		t.Logf("  call %d→%d: %v", i, i+1, interval)
	}

	// Check first interval is in the fast range (~500ms ± 200ms)
	firstInterval := times[1].Sub(times[0])
	if firstInterval < 300*time.Millisecond || firstInterval > 700*time.Millisecond {
		t.Errorf("first poll interval = %v, want ~500ms (±200ms)", firstInterval)
	}

	// If we have enough calls, check that later intervals are longer
	if len(times) >= 4 {
		lastEmptyInterval := times[len(times)-2].Sub(times[len(times)-3])
		if lastEmptyInterval < firstInterval-200*time.Millisecond {
			t.Errorf("later interval (%v) should be >= first interval (%v); backoff not working",
				lastEmptyInterval, firstInterval)
		}
	}
}

func TestProbeEndpointHealth_CustomProbePath(t *testing.T) {
	be := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/readyz":
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("ok"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer be.Close()

	endpoint, err := url.Parse(be.URL)
	if err != nil {
		t.Fatalf("parse backend url: %v", err)
	}

	sw := &ScaleWaker{
		client:    &http.Client{Timeout: 5 * time.Second},
		probePath: "/readyz",
	}

	if !sw.probeEndpointHealth(context.Background(), endpoint) {
		t.Fatal("probeEndpointHealth = false, want true with custom probe path")
	}
}
