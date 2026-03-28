// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeStateStore struct {
	mu               sync.Mutex
	err              error
	calls            int
	workloads        map[string]WorkloadRegistration
	synced           []WorkloadRegistration
	removed          int
	readyEndpoints   map[string]*url.URL
	activationStates map[string]ActivationState
	activities       []string
}

func (f *fakeStateStore) Ping(context.Context) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	return f.err
}

func (f *fakeStateStore) LookupWorkload(_ context.Context, host string) (WorkloadRegistration, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return WorkloadRegistration{}, false, f.err
	}
	record, ok := f.workloads[normalizeHost(host)]
	return record, ok, nil
}

func (f *fakeStateStore) SyncWorkloads(_ context.Context, workloads []WorkloadRegistration) (RegistrySyncResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return RegistrySyncResult{}, f.err
	}
	f.synced = append([]WorkloadRegistration(nil), workloads...)
	if f.workloads == nil {
		f.workloads = make(map[string]WorkloadRegistration, len(workloads))
	}
	for _, workload := range workloads {
		f.workloads[workload.HostName] = workload
	}
	return RegistrySyncResult{SyncedCount: len(workloads), RemovedCount: f.removed}, nil
}

func (f *fakeStateStore) LookupReadyEndpoint(_ context.Context, host string) (*url.URL, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return nil, false, f.err
	}
	endpoint, ok := f.readyEndpoints[normalizeHost(host)]
	return endpoint, ok, nil
}

func (f *fakeStateStore) SetReadyEndpoint(_ context.Context, host string, endpoint *url.URL, _ time.Duration) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return f.err
	}
	if f.readyEndpoints == nil {
		f.readyEndpoints = make(map[string]*url.URL)
	}
	f.readyEndpoints[normalizeHost(host)] = endpoint
	return nil
}

func (f *fakeStateStore) ClearReadyEndpoint(_ context.Context, host string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return f.err
	}
	delete(f.readyEndpoints, normalizeHost(host))
	return nil
}

func (f *fakeStateStore) GetActivationState(_ context.Context, host string) (ActivationState, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return ActivationState{}, false, f.err
	}
	state, ok := f.activationStates[normalizeHost(host)]
	return state, ok, nil
}

func (f *fakeStateStore) SetActivationState(_ context.Context, host string, state ActivationState, _ time.Duration) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return f.err
	}
	if f.activationStates == nil {
		f.activationStates = make(map[string]ActivationState)
	}
	if state.UpdatedAt.IsZero() {
		state.UpdatedAt = time.Now().UTC()
	}
	f.activationStates[normalizeHost(host)] = state
	return nil
}

func (f *fakeStateStore) ClearActivationState(_ context.Context, host string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return f.err
	}
	delete(f.activationStates, normalizeHost(host))
	return nil
}

func (f *fakeStateStore) AcquireWakeLock(context.Context, string, string, time.Duration) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return true, f.err
}

func (f *fakeStateStore) ReleaseWakeLock(context.Context, string, string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.err
}

func (f *fakeStateStore) GetJobSpec(context.Context, string) ([]byte, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return nil, false, f.err
}

func (f *fakeStateStore) SetActivity(_ context.Context, service string, _ time.Time) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return f.err
	}
	f.activities = append(f.activities, service)
	return nil
}

type fakeRuntime struct {
	endpoint    *url.URL
	err         error
	activations []WorkloadRegistration
}

func (f *fakeRuntime) Activate(_ context.Context, workload WorkloadRegistration) (*url.URL, error) {
	f.activations = append(f.activations, workload)
	if f.err != nil {
		return nil, f.err
	}
	return f.endpoint, nil
}

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func mustURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	parsed, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parse url %q: %v", raw, err)
	}
	return parsed
}

func testWorkload() WorkloadRegistration {
	return normalizeWorkloadRegistration(WorkloadRegistration{
		HostName:        "echo-s2z-0001.localhost",
		ServiceName:     "echo-s2z-0001",
		JobName:         "echo-s2z-0001",
		WorkloadClass:   "fast-api",
		WorkloadOrdinal: 1,
		JobSpecKey:      "scale-to-zero/jobs/echo-s2z-0001",
	})
}

func TestNormalizeHost(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		name  string
		input string
		want  string
	}{
		{name: "host with port", input: "Echo-S2Z-0001.localhost:80", want: "echo-s2z-0001.localhost"},
		{name: "ipv6 host", input: "[2001:db8::1]:8090", want: "2001:db8::1"},
		{name: "plain host", input: "echo-s2z-0002.localhost", want: "echo-s2z-0002.localhost"},
	}

	for _, tc := range testCases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := normalizeHost(tc.input); got != tc.want {
				t.Fatalf("normalizeHost(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}

func TestActivatorHealthz(t *testing.T) {
	t.Parallel()

	activator := NewActivator(testLogger(), &fakeStateStore{}, &fakeRuntime{}, time.Second)
	req := httptest.NewRequest(http.MethodGet, "http://activator/healthz", nil)
	resp := httptest.NewRecorder()

	activator.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", resp.Code, http.StatusOK)
	}
	if body := resp.Body.String(); body != "ok\n" {
		t.Fatalf("body = %q, want %q", body, "ok\n")
	}
}

func TestActivatorReadyz(t *testing.T) {
	t.Parallel()

	t.Run("ready", func(t *testing.T) {
		t.Parallel()

		store := &fakeStateStore{}
		activator := NewActivator(testLogger(), store, &fakeRuntime{}, time.Second)
		req := httptest.NewRequest(http.MethodGet, "http://activator/readyz", nil)
		resp := httptest.NewRecorder()

		activator.ServeHTTP(resp, req)

		if resp.Code != http.StatusOK {
			t.Fatalf("status = %d, want %d", resp.Code, http.StatusOK)
		}
		if body := resp.Body.String(); body != "ready\n" {
			t.Fatalf("body = %q, want %q", body, "ready\n")
		}
		if store.calls != 1 {
			t.Fatalf("calls = %d, want 1", store.calls)
		}
	})

	t.Run("store unavailable", func(t *testing.T) {
		t.Parallel()

		store := &fakeStateStore{err: errors.New("redis down")}
		activator := NewActivator(testLogger(), store, &fakeRuntime{}, time.Second)
		req := httptest.NewRequest(http.MethodGet, "http://activator/readyz", nil)
		resp := httptest.NewRecorder()

		activator.ServeHTTP(resp, req)

		if resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("status = %d, want %d", resp.Code, http.StatusServiceUnavailable)
		}
		if store.calls != 1 {
			t.Fatalf("calls = %d, want 1", store.calls)
		}
	})
}

func TestActivatorRegistrySync(t *testing.T) {
	t.Parallel()

	store := &fakeStateStore{}
	activator := NewActivator(testLogger(), store, &fakeRuntime{}, 45*time.Second)
	req := httptest.NewRequest(http.MethodPost, "http://activator/admin/registry/sync", strings.NewReader(`{
		"workloads": [
			{
				"host_name": "Echo-S2Z-0001.localhost",
				"service_name": "echo-s2z-0001",
				"job_name": "echo-s2z-0001",
				"workload_class": "fast-api",
				"workload_ordinal": 1,
				"job_spec_key": "scale-to-zero/jobs/echo-s2z-0001"
			}
		]
	}`))
	resp := httptest.NewRecorder()

	activator.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", resp.Code, http.StatusOK)
	}
	if len(store.synced) != 1 {
		t.Fatalf("synced len = %d, want 1", len(store.synced))
	}
	if got := store.synced[0].HostName; got != "echo-s2z-0001.localhost" {
		t.Fatalf("synced host = %q, want normalized host", got)
	}
	if got := store.synced[0].GroupName; got != defaultTaskGroupName {
		t.Fatalf("group_name = %q, want %q", got, defaultTaskGroupName)
	}
}

func TestActivatorRegistryLookup(t *testing.T) {
	t.Parallel()

	store := &fakeStateStore{
		workloads: map[string]WorkloadRegistration{
			"echo-s2z-0001.localhost": testWorkload(),
		},
	}
	activator := NewActivator(testLogger(), store, &fakeRuntime{}, 45*time.Second)
	req := httptest.NewRequest(http.MethodGet, "http://activator/registry/lookup?host=echo-s2z-0001.localhost", nil)
	resp := httptest.NewRecorder()

	activator.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", resp.Code, http.StatusOK)
	}

	var payload RegistryLookupResponse
	if err := json.Unmarshal(resp.Body.Bytes(), &payload); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	if payload.Status != "found" {
		t.Fatalf("status payload = %q, want found", payload.Status)
	}
	if payload.Workload == nil || payload.Workload.ServiceName != "echo-s2z-0001" {
		t.Fatalf("unexpected workload payload: %#v", payload.Workload)
	}
}

func TestActivatorActivateContract(t *testing.T) {
	t.Parallel()

	store := &fakeStateStore{
		workloads: map[string]WorkloadRegistration{
			"echo-s2z-0001.localhost": testWorkload(),
		},
	}
	runtime := &fakeRuntime{endpoint: mustURL(t, "http://127.0.0.1:19090")}
	activator := NewActivator(testLogger(), store, runtime, 45*time.Second)
	req := httptest.NewRequest(http.MethodPost, "http://activator/activate", strings.NewReader(`{
		"host": "echo-s2z-0001.localhost:80",
		"method": "get",
		"path": "/metadata",
		"request_id": "req-123"
	}`))
	resp := httptest.NewRecorder()

	activator.ServeHTTP(resp, req)

	if resp.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", resp.Code, http.StatusOK)
	}

	var payload ActivateResponse
	if err := json.Unmarshal(resp.Body.Bytes(), &payload); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	if payload.Status != "ready" {
		t.Fatalf("status payload = %q, want ready", payload.Status)
	}
	if payload.TargetURL != "http://127.0.0.1:19090" {
		t.Fatalf("target_url = %q, want %q", payload.TargetURL, "http://127.0.0.1:19090")
	}
	if len(runtime.activations) != 1 {
		t.Fatalf("activations = %d, want 1", len(runtime.activations))
	}
}

func TestActivatorProxyRequest(t *testing.T) {
	t.Parallel()

	var gotPath, gotQuery, gotHost string
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotQuery = r.URL.RawQuery
		gotHost = r.Host
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte("proxied"))
	}))
	defer backend.Close()

	store := &fakeStateStore{
		workloads: map[string]WorkloadRegistration{
			"echo-s2z-0001.localhost": testWorkload(),
		},
	}
	runtime := &fakeRuntime{endpoint: mustURL(t, backend.URL)}
	activator := NewActivator(testLogger(), store, runtime, 45*time.Second)
	req := httptest.NewRequest(http.MethodGet, "http://echo-s2z-0001.localhost/metadata?full=true", nil)
	req.Host = "echo-s2z-0001.localhost"
	resp := httptest.NewRecorder()

	activator.ServeHTTP(resp, req)

	if resp.Code != http.StatusAccepted {
		t.Fatalf("status = %d, want %d", resp.Code, http.StatusAccepted)
	}
	if gotPath != "/metadata" {
		t.Fatalf("backend path = %q, want %q", gotPath, "/metadata")
	}
	if gotQuery != "full=true" {
		t.Fatalf("backend query = %q, want %q", gotQuery, "full=true")
	}
	if gotHost != "echo-s2z-0001.localhost" {
		t.Fatalf("backend host = %q, want %q", gotHost, "echo-s2z-0001.localhost")
	}
	// Expect two activity writes: early (before activation) and refresh (after proxy).
	if len(store.activities) != 2 || store.activities[0] != "echo-s2z-0001" || store.activities[1] != "echo-s2z-0001" {
		t.Fatalf("activities = %#v, want two activity updates for echo-s2z-0001", store.activities)
	}
}

func TestActivatorProxyRequestUnknownHost(t *testing.T) {
	t.Parallel()

	activator := NewActivator(testLogger(), &fakeStateStore{}, &fakeRuntime{}, 45*time.Second)
	req := httptest.NewRequest(http.MethodGet, "http://unknown.localhost/some/path", nil)
	req.Host = "unknown.localhost"
	resp := httptest.NewRecorder()

	activator.ServeHTTP(resp, req)

	if resp.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d", resp.Code, http.StatusNotFound)
	}

	var payload map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &payload); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	if got := payload["status"]; got != "not_found" {
		t.Fatalf("status payload = %v, want not_found", got)
	}
}
