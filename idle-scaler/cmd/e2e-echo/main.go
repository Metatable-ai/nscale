// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	responseModeText = "text"
	responseModeJSON = "json"

	healthModeAlwaysHealthy   = "always-healthy"
	healthModeStartupGated    = "startup-gated"
	healthModeDependencyGated = "dependency-gated"
)

type workloadConfig struct {
	ListenAddr        string
	LogLevel          slog.Level
	ServiceName       string
	WorkloadClass     string
	WorkloadOrdinal   string
	ResponseText      string
	ResponseMode      string
	IdleTimeout       string
	StartupDelay      time.Duration
	HealthMode        string
	DependencyURL     string
	DependencyHost    string
	DependencyTimeout time.Duration
}

type dependencyProbe func(context.Context) error

type echoApp struct {
	cfg             workloadConfig
	logger          *slog.Logger
	now             func() time.Time
	readyAt         time.Time
	dependencyProbe dependencyProbe
}

type dependencyMetadata struct {
	URL  string `json:"url,omitempty"`
	Host string `json:"host,omitempty"`
}

type workloadResponse struct {
	Service      string              `json:"service"`
	Class        string              `json:"class"`
	Ordinal      string              `json:"ordinal,omitempty"`
	Message      string              `json:"message"`
	IdleTimeout  string              `json:"idle_timeout,omitempty"`
	Path         string              `json:"path"`
	Dependency   *dependencyMetadata `json:"dependency,omitempty"`
	StartupDelay string              `json:"startup_delay,omitempty"`
	HealthMode   string              `json:"health_mode,omitempty"`
}

type readinessPayload struct {
	Service string `json:"service"`
	Class   string `json:"class"`
	Status  string `json:"status"`
	Error   string `json:"error"`
}

type metadataResponse struct {
	Service      string              `json:"service"`
	Class        string              `json:"class"`
	Ordinal      string              `json:"ordinal,omitempty"`
	ResponseMode string              `json:"response_mode"`
	StartupDelay string              `json:"startup_delay"`
	HealthMode   string              `json:"health_mode"`
	IdleTimeout  string              `json:"idle_timeout,omitempty"`
	Dependency   *dependencyMetadata `json:"dependency,omitempty"`
}

func envOrDefault(key, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}

	return value
}

func envOrDefaultDuration(key string, fallback time.Duration) time.Duration {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return fallback
	}

	if parsed, err := time.ParseDuration(raw); err == nil {
		return parsed
	}

	if seconds, err := strconv.Atoi(raw); err == nil {
		return time.Duration(seconds) * time.Second
	}

	return fallback
}

func listenAddr() string {
	if addr := os.Getenv("E2E_ECHO_LISTEN_ADDR"); addr != "" {
		return addr
	}

	port := envOrDefault("NOMAD_PORT_http", "8080")
	return ":" + port
}

func loadEchoConfigFromEnv() workloadConfig {
	dependencyURL := strings.TrimSpace(os.Getenv("E2E_ECHO_DEPENDENCY_URL"))

	return workloadConfig{
		ListenAddr:        listenAddr(),
		LogLevel:          parseEchoLogLevel(os.Getenv("LOG_LEVEL")),
		ServiceName:       envOrDefault("E2E_ECHO_SERVICE_NAME", "e2e-echo"),
		WorkloadClass:     envOrDefault("E2E_ECHO_WORKLOAD_CLASS", "fast-api"),
		WorkloadOrdinal:   envOrDefault("E2E_ECHO_WORKLOAD_ORDINAL", "1"),
		ResponseText:      envOrDefault("E2E_ECHO_TEXT", "Hello from e2e echo"),
		ResponseMode:      normalizeResponseMode(os.Getenv("E2E_ECHO_RESPONSE_MODE")),
		IdleTimeout:       strings.TrimSpace(os.Getenv("E2E_ECHO_IDLE_TIMEOUT")),
		StartupDelay:      envOrDefaultDuration("E2E_ECHO_STARTUP_DELAY", 0),
		HealthMode:        normalizeHealthMode(os.Getenv("E2E_ECHO_HEALTH_MODE"), dependencyURL),
		DependencyURL:     dependencyURL,
		DependencyHost:    strings.TrimSpace(os.Getenv("E2E_ECHO_DEPENDENCY_HOST")),
		DependencyTimeout: envOrDefaultDuration("E2E_ECHO_DEPENDENCY_TIMEOUT", 10*time.Second),
	}
}

func newEchoApp(cfg workloadConfig, logger *slog.Logger, now func() time.Time, probe dependencyProbe) *echoApp {
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(os.Stdout, nil))
	}
	if now == nil {
		now = time.Now
	}
	if probe == nil {
		probe = newHTTPDependencyProbe(cfg)
	}

	return &echoApp{
		cfg:             cfg,
		logger:          logger,
		now:             now,
		readyAt:         now().Add(cfg.StartupDelay),
		dependencyProbe: probe,
	}
}

func newHTTPDependencyProbe(cfg workloadConfig) dependencyProbe {
	if cfg.DependencyURL == "" {
		return func(context.Context) error { return nil }
	}

	client := &http.Client{Timeout: cfg.DependencyTimeout}

	return func(ctx context.Context) error {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, cfg.DependencyURL, nil)
		if err != nil {
			return err
		}
		if cfg.DependencyHost != "" {
			req.Host = cfg.DependencyHost
		}

		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()

		if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusBadRequest {
			return fmt.Errorf("dependency returned status %d", resp.StatusCode)
		}

		return nil
	}
}

func normalizeResponseMode(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case responseModeJSON:
		return responseModeJSON
	default:
		return responseModeText
	}
}

func normalizeHealthMode(raw, dependencyURL string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "always-ok", healthModeAlwaysHealthy:
		return healthModeAlwaysHealthy
	case "dependency", healthModeDependencyGated:
		return healthModeDependencyGated
	case "startup", healthModeStartupGated:
		return healthModeStartupGated
	case "":
		if strings.TrimSpace(dependencyURL) != "" {
			return healthModeDependencyGated
		}
		return healthModeStartupGated
	default:
		return healthModeStartupGated
	}
}

func main() {
	cfg := loadEchoConfigFromEnv()
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel})).With(
		"service", "e2e-echo",
		"workload_class", cfg.WorkloadClass,
		"service_name", cfg.ServiceName,
	)

	app := newEchoApp(cfg, logger, nil, nil)
	server := &http.Server{
		Addr:    cfg.ListenAddr,
		Handler: app,
	}

	logger.Info("starting e2e workload server", "addr", cfg.ListenAddr, "startup_delay", cfg.StartupDelay.String(), "health_mode", cfg.HealthMode)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		logger.Error("failed to start e2e workload server", "error", err)
		os.Exit(1)
	}
}

func (a *echoApp) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/metadata" {
		a.writeMetadata(w)
		return
	}

	if r.URL.Path == "/readyz" {
		if err := a.startupReadinessError(); err != nil {
			a.writeNotReady(w, err)
			return
		}
		a.writeReadyCheck(w)
		return
	}

	if err := a.readinessError(r.Context()); err != nil {
		a.writeNotReady(w, err)
		return
	}

	if r.URL.Path == "/healthz" {
		a.writeReadyCheck(w)
		return
	}

	a.writeReadyResponse(w, r)
}

func (a *echoApp) startupReadinessError() error {
	if a.cfg.HealthMode == healthModeAlwaysHealthy {
		return nil
	}

	now := a.now()
	if now.Before(a.readyAt) {
		remaining := a.readyAt.Sub(now).Round(time.Second)
		if remaining < 0 {
			remaining = 0
		}
		return fmt.Errorf("warming up (%s remaining)", remaining)
	}

	return nil
}

func (a *echoApp) readinessError(ctx context.Context) error {
	if err := a.startupReadinessError(); err != nil {
		return err
	}

	if a.cfg.HealthMode != healthModeDependencyGated {
		return nil
	}

	if err := a.dependencyProbe(ctx); err != nil {
		return fmt.Errorf("dependency unavailable: %w", err)
	}

	return nil
}

func (a *echoApp) writeReadyCheck(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}

func (a *echoApp) writeMetadata(w http.ResponseWriter) {
	payload := metadataResponse{
		Service:      a.cfg.ServiceName,
		Class:        a.cfg.WorkloadClass,
		Ordinal:      a.cfg.WorkloadOrdinal,
		ResponseMode: a.cfg.ResponseMode,
		StartupDelay: a.cfg.StartupDelay.String(),
		HealthMode:   a.cfg.HealthMode,
		IdleTimeout:  a.cfg.IdleTimeout,
		Dependency:   a.dependencyMetadata(),
	}

	a.writeJSON(w, http.StatusOK, payload)
}

func (a *echoApp) writeReadyResponse(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-E2E-Service-Name", a.cfg.ServiceName)
	w.Header().Set("X-E2E-Workload-Class", a.cfg.WorkloadClass)
	if a.cfg.IdleTimeout != "" {
		w.Header().Set("X-E2E-Idle-Timeout", a.cfg.IdleTimeout)
	}

	if a.cfg.ResponseMode == responseModeJSON {
		payload := workloadResponse{
			Service:      a.cfg.ServiceName,
			Class:        a.cfg.WorkloadClass,
			Ordinal:      a.cfg.WorkloadOrdinal,
			Message:      a.cfg.ResponseText,
			IdleTimeout:  a.cfg.IdleTimeout,
			Path:         r.URL.Path,
			Dependency:   a.dependencyMetadata(),
			StartupDelay: a.cfg.StartupDelay.String(),
			HealthMode:   a.cfg.HealthMode,
		}
		a.writeJSON(w, http.StatusOK, payload)
		return
	}

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(a.cfg.ResponseText))
}

func (a *echoApp) writeNotReady(w http.ResponseWriter, err error) {
	a.logger.Debug("workload not ready", "error", err)
	if a.cfg.ResponseMode == responseModeJSON {
		payload := readinessPayload{
			Service: a.cfg.ServiceName,
			Class:   a.cfg.WorkloadClass,
			Status:  "warming",
			Error:   err.Error(),
		}
		a.writeJSON(w, http.StatusServiceUnavailable, payload)
		return
	}

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusServiceUnavailable)
	_, _ = w.Write([]byte(err.Error() + "\n"))
}

func (a *echoApp) dependencyMetadata() *dependencyMetadata {
	if a.cfg.DependencyURL == "" && a.cfg.DependencyHost == "" {
		return nil
	}

	return &dependencyMetadata{
		URL:  a.cfg.DependencyURL,
		Host: a.cfg.DependencyHost,
	}
}

func (a *echoApp) writeJSON(w http.ResponseWriter, statusCode int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(statusCode)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		a.logger.Error("failed to encode response", "error", err)
	}
}

func parseEchoLogLevel(raw string) slog.Level {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
