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
	"testing"
	"time"
)

func TestLoadEchoConfigFromEnv(t *testing.T) {
	tests := []struct {
		name         string
		env          map[string]string
		wantAddr     string
		wantMode     string
		wantHealth   string
		wantDelay    time.Duration
		wantClass    string
		wantService  string
		wantIdle     string
		wantDepHost  string
		wantLogLevel slog.Level
	}{
		{
			name: "defaults from nomad port",
			env: map[string]string{
				"NOMAD_PORT_http": "19090",
			},
			wantAddr:     ":19090",
			wantMode:     responseModeText,
			wantHealth:   healthModeStartupGated,
			wantDelay:    0,
			wantClass:    "fast-api",
			wantService:  "e2e-echo",
			wantLogLevel: slog.LevelInfo,
		},
		{
			name: "dependency defaults to dependency gated json response",
			env: map[string]string{
				"E2E_ECHO_LISTEN_ADDR":     ":8088",
				"E2E_ECHO_RESPONSE_MODE":   "json",
				"E2E_ECHO_DEPENDENCY_URL":  "http://traefik:80",
				"E2E_ECHO_DEPENDENCY_HOST": "echo-s2z-0001.localhost",
				"E2E_ECHO_STARTUP_DELAY":   "12",
				"E2E_ECHO_WORKLOAD_CLASS":  "dependency-sensitive",
				"E2E_ECHO_SERVICE_NAME":    "echo-s2z-0003",
				"E2E_ECHO_IDLE_TIMEOUT":    "15s",
				"LOG_LEVEL":                "warn",
			},
			wantAddr:     ":8088",
			wantMode:     responseModeJSON,
			wantHealth:   healthModeDependencyGated,
			wantDelay:    12 * time.Second,
			wantClass:    "dependency-sensitive",
			wantService:  "echo-s2z-0003",
			wantIdle:     "15s",
			wantDepHost:  "echo-s2z-0001.localhost",
			wantLogLevel: slog.LevelWarn,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			for key, value := range tt.env {
				t.Setenv(key, value)
			}

			cfg := loadEchoConfigFromEnv()
			if cfg.ListenAddr != tt.wantAddr {
				t.Fatalf("ListenAddr = %q, want %q", cfg.ListenAddr, tt.wantAddr)
			}
			if cfg.ResponseMode != tt.wantMode {
				t.Fatalf("ResponseMode = %q, want %q", cfg.ResponseMode, tt.wantMode)
			}
			if cfg.HealthMode != tt.wantHealth {
				t.Fatalf("HealthMode = %q, want %q", cfg.HealthMode, tt.wantHealth)
			}
			if cfg.StartupDelay != tt.wantDelay {
				t.Fatalf("StartupDelay = %v, want %v", cfg.StartupDelay, tt.wantDelay)
			}
			if cfg.WorkloadClass != tt.wantClass {
				t.Fatalf("WorkloadClass = %q, want %q", cfg.WorkloadClass, tt.wantClass)
			}
			if cfg.ServiceName != tt.wantService {
				t.Fatalf("ServiceName = %q, want %q", cfg.ServiceName, tt.wantService)
			}
			if cfg.IdleTimeout != tt.wantIdle {
				t.Fatalf("IdleTimeout = %q, want %q", cfg.IdleTimeout, tt.wantIdle)
			}
			if cfg.DependencyHost != tt.wantDepHost {
				t.Fatalf("DependencyHost = %q, want %q", cfg.DependencyHost, tt.wantDepHost)
			}
			if cfg.LogLevel != tt.wantLogLevel {
				t.Fatalf("LogLevel = %v, want %v", cfg.LogLevel, tt.wantLogLevel)
			}
		})
	}
}

func TestEchoAppHandler(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	t.Run("fast api returns json payload", func(t *testing.T) {
		t.Parallel()

		cfg := workloadConfig{
			ServiceName:     "echo-s2z-0001",
			WorkloadClass:   "fast-api",
			WorkloadOrdinal: "1",
			ResponseText:    "Hello from fast API",
			ResponseMode:    responseModeJSON,
			HealthMode:      healthModeStartupGated,
			IdleTimeout:     "10s",
		}
		app := newEchoApp(cfg, logger, func() time.Time { return time.Unix(1700000000, 0) }, nil)

		resp := httptest.NewRecorder()
		app.ServeHTTP(resp, httptest.NewRequest(http.MethodGet, "http://example/", nil))
		if resp.Code != http.StatusOK {
			t.Fatalf("status = %d, want %d", resp.Code, http.StatusOK)
		}

		var payload workloadResponse
		if err := json.Unmarshal(resp.Body.Bytes(), &payload); err != nil {
			t.Fatalf("failed to decode json response: %v", err)
		}
		if payload.Service != cfg.ServiceName {
			t.Fatalf("service = %q, want %q", payload.Service, cfg.ServiceName)
		}
		if payload.Class != cfg.WorkloadClass {
			t.Fatalf("class = %q, want %q", payload.Class, cfg.WorkloadClass)
		}
		if payload.Message != cfg.ResponseText {
			t.Fatalf("message = %q, want %q", payload.Message, cfg.ResponseText)
		}
	})

	t.Run("slow start stays unhealthy until startup delay passes", func(t *testing.T) {
		t.Parallel()

		current := time.Unix(1700000000, 0)
		cfg := workloadConfig{
			ServiceName:     "echo-s2z-0002",
			WorkloadClass:   "slow-start",
			WorkloadOrdinal: "1",
			ResponseText:    "Slow start ready",
			ResponseMode:    responseModeText,
			HealthMode:      healthModeStartupGated,
			StartupDelay:    10 * time.Second,
		}
		app := newEchoApp(cfg, logger, func() time.Time { return current }, nil)

		healthResp := httptest.NewRecorder()
		app.ServeHTTP(healthResp, httptest.NewRequest(http.MethodGet, "http://example/healthz", nil))
		if healthResp.Code != http.StatusServiceUnavailable {
			t.Fatalf("initial health status = %d, want %d", healthResp.Code, http.StatusServiceUnavailable)
		}

		current = current.Add(11 * time.Second)

		healthResp = httptest.NewRecorder()
		app.ServeHTTP(healthResp, httptest.NewRequest(http.MethodGet, "http://example/healthz", nil))
		if healthResp.Code != http.StatusOK {
			t.Fatalf("ready health status = %d, want %d", healthResp.Code, http.StatusOK)
		}

		appResp := httptest.NewRecorder()
		app.ServeHTTP(appResp, httptest.NewRequest(http.MethodGet, "http://example/", nil))
		if appResp.Code != http.StatusOK {
			t.Fatalf("ready app status = %d, want %d", appResp.Code, http.StatusOK)
		}
	})

	t.Run("dependency sensitive waits for dependency probe", func(t *testing.T) {
		t.Parallel()

		dependencyReady := false
		cfg := workloadConfig{
			ServiceName:       "echo-s2z-0003",
			WorkloadClass:     "dependency-sensitive",
			WorkloadOrdinal:   "1",
			ResponseText:      "Dependency ready",
			ResponseMode:      responseModeJSON,
			HealthMode:        healthModeDependencyGated,
			DependencyURL:     "http://traefik:80",
			DependencyHost:    "echo-s2z-0001.localhost",
			DependencyTimeout: 5 * time.Second,
		}
		app := newEchoApp(cfg, logger, func() time.Time { return time.Unix(1700000000, 0) }, func(context.Context) error {
			if !dependencyReady {
				return errors.New("dependency unavailable")
			}
			return nil
		})

		firstResp := httptest.NewRecorder()
		app.ServeHTTP(firstResp, httptest.NewRequest(http.MethodGet, "http://example/", nil))
		if firstResp.Code != http.StatusServiceUnavailable {
			t.Fatalf("status before dependency ready = %d, want %d", firstResp.Code, http.StatusServiceUnavailable)
		}

		healthResp := httptest.NewRecorder()
		app.ServeHTTP(healthResp, httptest.NewRequest(http.MethodGet, "http://example/healthz", nil))
		if healthResp.Code != http.StatusServiceUnavailable {
			t.Fatalf("dependency health status = %d, want %d", healthResp.Code, http.StatusServiceUnavailable)
		}

		readyResp := httptest.NewRecorder()
		app.ServeHTTP(readyResp, httptest.NewRequest(http.MethodGet, "http://example/readyz", nil))
		if readyResp.Code != http.StatusOK {
			t.Fatalf("local readiness status = %d, want %d", readyResp.Code, http.StatusOK)
		}

		dependencyReady = true

		healthResp = httptest.NewRecorder()
		app.ServeHTTP(healthResp, httptest.NewRequest(http.MethodGet, "http://example/healthz", nil))
		if healthResp.Code != http.StatusOK {
			t.Fatalf("dependency health after ready = %d, want %d", healthResp.Code, http.StatusOK)
		}

		secondResp := httptest.NewRecorder()
		app.ServeHTTP(secondResp, httptest.NewRequest(http.MethodGet, "http://example/", nil))
		if secondResp.Code != http.StatusOK {
			t.Fatalf("status after dependency ready = %d, want %d", secondResp.Code, http.StatusOK)
		}

		var payload workloadResponse
		if err := json.Unmarshal(secondResp.Body.Bytes(), &payload); err != nil {
			t.Fatalf("failed to decode dependency response: %v", err)
		}
		if payload.Dependency == nil || payload.Dependency.Host != cfg.DependencyHost {
			t.Fatalf("dependency metadata = %#v, want host %q", payload.Dependency, cfg.DependencyHost)
		}
	})

	t.Run("metadata endpoint is always available", func(t *testing.T) {
		t.Parallel()

		cfg := workloadConfig{
			ServiceName:     "echo-s2z-0004",
			WorkloadClass:   "slow-start",
			WorkloadOrdinal: "2",
			ResponseText:    "metadata",
			ResponseMode:    responseModeText,
			HealthMode:      healthModeStartupGated,
			StartupDelay:    30 * time.Second,
		}
		app := newEchoApp(cfg, logger, func() time.Time { return time.Unix(1700000000, 0) }, nil)

		resp := httptest.NewRecorder()
		app.ServeHTTP(resp, httptest.NewRequest(http.MethodGet, "http://example/metadata", nil))
		if resp.Code != http.StatusOK {
			t.Fatalf("metadata status = %d, want %d", resp.Code, http.StatusOK)
		}
	})
}
