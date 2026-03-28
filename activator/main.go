// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	defaultListenAddr     = ":8090"
	defaultRequestTimeout = 45 * time.Second
	defaultActivationTTL  = 90 * time.Second
	redisPingTimeout      = 5 * time.Second
	readyzPingTimeout     = 2 * time.Second
)

type Config struct {
	ListenAddr     string
	RedisAddr      string
	RedisPassword  string
	RedisDB        int
	NomadAddr      string
	ConsulAddr     string
	NomadToken     string
	ConsulToken    string
	RequestTimeout time.Duration
	ActivationTTL  time.Duration
	ProbePath      string
}

type Activator struct {
	logger         *slog.Logger
	stateStore     stateStore
	runtime        requestRuntime
	requestTimeout time.Duration
}

func NewActivator(logger *slog.Logger, stateStore stateStore, runtime requestRuntime, requestTimeout time.Duration) *Activator {
	if logger == nil {
		logger = newJSONLogger("activator")
	}
	if requestTimeout <= 0 {
		requestTimeout = defaultRequestTimeout
	}

	return &Activator{
		logger:         logger,
		stateStore:     stateStore,
		runtime:        runtime,
		requestTimeout: requestTimeout,
	}
}

func (a *Activator) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/healthz":
		writeText(w, http.StatusOK, "ok\n")
	case "/readyz":
		a.handleReadyz(w, r)
	case "/admin/registry/sync":
		a.handleRegistrySync(w, r)
	case "/registry/lookup":
		a.handleRegistryLookup(w, r)
	case "/activate":
		a.handleActivate(w, r)
	default:
		a.handleProxyRequest(w, r)
	}
}

func (a *Activator) handleReadyz(w http.ResponseWriter, r *http.Request) {
	if a.stateStore == nil {
		http.Error(w, "state store is not configured", http.StatusServiceUnavailable)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), readyzPingTimeout)
	defer cancel()

	if err := a.stateStore.Ping(ctx); err != nil {
		http.Error(w, "state store is unavailable: "+err.Error(), http.StatusServiceUnavailable)
		return
	}

	writeText(w, http.StatusOK, "ready\n")
}

func (a *Activator) handleRegistrySync(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if a.stateStore == nil {
		http.Error(w, "state store is not configured", http.StatusServiceUnavailable)
		return
	}

	var request RegistrySyncRequest
	if err := decodeJSONBody(r.Body, &request); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	workloads := make([]WorkloadRegistration, 0, len(request.Workloads))
	seenHosts := make(map[string]struct{}, len(request.Workloads))
	for _, record := range request.Workloads {
		record = normalizeWorkloadRegistration(record)
		if err := record.validate(); err != nil {
			http.Error(w, fmt.Sprintf("invalid workload registration for host %q: %v", record.HostName, err), http.StatusBadRequest)
			return
		}
		if _, exists := seenHosts[record.HostName]; exists {
			http.Error(w, fmt.Sprintf("duplicate host_name %q in sync request", record.HostName), http.StatusBadRequest)
			return
		}
		seenHosts[record.HostName] = struct{}{}
		workloads = append(workloads, record)
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	result, err := a.stateStore.SyncWorkloads(ctx, workloads)
	if err != nil {
		http.Error(w, "sync workloads: "+err.Error(), http.StatusBadGateway)
		return
	}

	a.logger.Info("synced activator registry workloads",
		"workload_count", result.SyncedCount,
		"removed_count", result.RemovedCount,
	)

	writeJSON(w, http.StatusOK, RegistrySyncResponse{
		Status:       "ok",
		SyncedCount:  result.SyncedCount,
		RemovedCount: result.RemovedCount,
	})
}

func (a *Activator) handleRegistryLookup(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	host := normalizeHost(r.URL.Query().Get("host"))
	if host == "" {
		http.Error(w, "host query parameter is required", http.StatusBadRequest)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	workload, found, err := a.lookupWorkload(ctx, host)
	if err != nil {
		http.Error(w, "lookup workload: "+err.Error(), http.StatusBadGateway)
		return
	}
	if !found {
		writeJSON(w, http.StatusNotFound, RegistryLookupResponse{
			Status:   "not_found",
			HostName: host,
			Message:  "host is not registered in the activator registry",
		})
		return
	}

	writeJSON(w, http.StatusOK, RegistryLookupResponse{
		Status:   "found",
		HostName: host,
		Workload: &workload,
	})
}

func (a *Activator) handleActivate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if a.runtime == nil {
		http.Error(w, "activator runtime is not configured", http.StatusServiceUnavailable)
		return
	}

	var request ActivateRequest
	if err := decodeJSONBody(r.Body, &request); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	request = normalizeActivateRequest(request)
	if err := request.validate(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), a.requestTimeout)
	defer cancel()

	workload, found, err := a.lookupWorkload(ctx, request.Host)
	if err != nil {
		http.Error(w, "lookup workload: "+err.Error(), http.StatusBadGateway)
		return
	}
	if !found {
		writeJSON(w, http.StatusNotFound, ActivateResponse{
			Status:         "not_found",
			Mode:           "hold-and-proxy",
			HostName:       request.Host,
			RequestID:      request.RequestID,
			RequestTimeout: a.requestTimeout.String(),
			HoldRequest:    true,
			Message:        "host is not registered in the activator registry",
		})
		return
	}

	target, err := a.runtime.Activate(ctx, workload)
	if err != nil {
		w.Header().Set("Retry-After", "1")
		writeJSON(w, activationStatusCode(err), ActivateResponse{
			Status:         "activation_failed",
			Mode:           "hold-and-proxy",
			HostName:       request.Host,
			RequestID:      request.RequestID,
			RequestTimeout: a.requestTimeout.String(),
			HoldRequest:    true,
			Workload:       &workload,
			Message:        err.Error(),
		})
		return
	}

	a.logger.Info("activator contract request is ready",
		"host", request.Host,
		"method", request.Method,
		"path", request.Path,
		"request_id", request.RequestID,
		"service_name", workload.ServiceName,
		"job_name", workload.JobName,
		"target", target.String(),
	)

	writeJSON(w, http.StatusOK, ActivateResponse{
		Status:         "ready",
		Mode:           "hold-and-proxy",
		HostName:       request.Host,
		RequestID:      request.RequestID,
		RequestTimeout: a.requestTimeout.String(),
		HoldRequest:    true,
		Workload:       &workload,
		TargetURL:      target.String(),
		Message:        "backend is ready for the held request",
	})
}

func (a *Activator) handleProxyRequest(w http.ResponseWriter, r *http.Request) {
	if a.stateStore == nil || a.runtime == nil {
		http.Error(w, "activator is not fully configured", http.StatusServiceUnavailable)
		return
	}

	host := normalizeHost(r.Host)
	if host == "" {
		host = normalizeHost(r.Header.Get("Host"))
	}
	if host == "" {
		http.Error(w, "request host is required", http.StatusBadRequest)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), a.requestTimeout)
	defer cancel()

	workload, found, err := a.lookupWorkload(ctx, host)
	if err != nil {
		http.Error(w, "lookup workload: "+err.Error(), http.StatusBadGateway)
		return
	}
	if !found {
		writeJSON(w, http.StatusNotFound, map[string]any{
			"status":          "not_found",
			"host":            host,
			"message":         "host is not registered in the activator registry",
			"request_timeout": a.requestTimeout.String(),
		})
		return
	}

	// Write activity early so the scale-down controller never races us during activation.
	if err := a.stateStore.SetActivity(ctx, workload.ServiceName, time.Now()); err != nil {
		a.logger.Warn("activator early activity update failed",
			"host", host,
			"service_name", workload.ServiceName,
			"error", err,
		)
	}

	target, err := a.runtime.Activate(ctx, workload)
	if err != nil {
		a.logger.Error("activator request failed to wake backend",
			"host", host,
			"service_name", workload.ServiceName,
			"job_name", workload.JobName,
			"path", r.URL.Path,
			"error", err,
		)
		w.Header().Set("Retry-After", "1")
		writeJSON(w, activationStatusCode(err), map[string]any{
			"status":          "activation_failed",
			"host":            host,
			"service_name":    workload.ServiceName,
			"job_name":        workload.JobName,
			"message":         err.Error(),
			"request_timeout": a.requestTimeout.String(),
		})
		return
	}

	// Refresh activity after successful activation to reflect actual proxy time.
	if err := a.stateStore.SetActivity(ctx, workload.ServiceName, time.Now()); err != nil {
		a.logger.Warn("activator activity refresh failed",
			"host", host,
			"service_name", workload.ServiceName,
			"error", err,
		)
	}

	a.logger.Info("proxying activator cold request to backend",
		"host", host,
		"service_name", workload.ServiceName,
		"job_name", workload.JobName,
		"target", target.String(),
		"path", r.URL.Path,
	)
	proxyTo(w, r, target, a.logger.With("host", host, "target", target.String()))
}

func (a *Activator) lookupWorkload(ctx context.Context, host string) (WorkloadRegistration, bool, error) {
	if a.stateStore == nil {
		return WorkloadRegistration{}, false, errors.New("state store is not configured")
	}
	return a.stateStore.LookupWorkload(ctx, host)
}

func main() {
	logger := newJSONLogger("activator")

	cfg, err := loadConfig()
	if err != nil {
		logger.Error("invalid activator configuration", "error", err)
		os.Exit(1)
	}

	store := newRedisStateStore(cfg)

	ctx, cancel := context.WithTimeout(context.Background(), redisPingTimeout)
	if err := store.Ping(ctx); err != nil {
		cancel()
		logger.Error("initial redis ping failed", "error", err, "redis_addr", cfg.RedisAddr)
		os.Exit(1)
	}
	cancel()

	runtime := newNomadRuntime(logger, store, cfg)
	activator := NewActivator(logger, store, runtime, cfg.RequestTimeout)
	server := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           activator,
		ReadHeaderTimeout: 5 * time.Second,
	}

	logger.Info("activator starting",
		"listen_addr", cfg.ListenAddr,
		"redis_addr", cfg.RedisAddr,
		"nomad_addr", cfg.NomadAddr,
		"consul_addr", cfg.ConsulAddr,
		"probe_path", cfg.ProbePath,
		"request_timeout", cfg.RequestTimeout.String(),
		"activation_timeout", cfg.ActivationTTL.String(),
	)

	shutdownCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	serverErr := make(chan error, 1)
	go func() {
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErr <- err
			return
		}
		serverErr <- nil
	}()

	select {
	case err := <-serverErr:
		if err != nil {
			logger.Error("activator server failed", "error", err)
			os.Exit(1)
		}
	case <-shutdownCtx.Done():
		logger.Info("activator shutting down")
	}

	ctx, cancel = context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		logger.Error("activator shutdown failed", "error", err)
		os.Exit(1)
	}
}

func loadConfig() (Config, error) {
	var cfg Config

	listenAddr := flag.String("listen-addr", envOrDefault("ACTIVATOR_ADDR", defaultListenAddr), "Activator listen address")
	redisAddr := flag.String("redis-addr", envOrDefault("REDIS_ADDR", ""), "Redis address")
	redisPassword := flag.String("redis-password", envOrDefault("REDIS_PASSWORD", ""), "Redis password")
	redisDB := flag.Int("redis-db", envOrDefaultInt("REDIS_DB", 0), "Redis database number")
	nomadAddr := flag.String("nomad-addr", envOrDefault("NOMAD_ADDR", ""), "Nomad address")
	consulAddr := flag.String("consul-addr", envOrDefault("CONSUL_ADDR", ""), "Consul address")
	nomadToken := flag.String("nomad-token", envOrDefault("NOMAD_TOKEN", envOrDefault("S2Z_NOMAD_TOKEN", "")), "Nomad ACL token")
	consulToken := flag.String("consul-token", envOrDefault("CONSUL_TOKEN", envOrDefault("S2Z_CONSUL_TOKEN", "")), "Consul ACL token")
	probePath := flag.String("probe-path", envOrDefault("ACTIVATOR_PROBE_PATH", "/healthz"), "Backend readiness probe path")
	requestTimeout := flag.Duration("request-timeout", envOrDefaultDuration("ACTIVATOR_REQUEST_TIMEOUT", defaultRequestTimeout), "Maximum time to hold the first request while a backend wakes")
	activationTimeout := flag.Duration("activation-timeout", envOrDefaultDuration("ACTIVATOR_ACTIVATION_TIMEOUT", 0), "Maximum time a backend activation may continue after the first request times out")
	flag.Parse()

	resolvedActivationTTL := *activationTimeout
	if resolvedActivationTTL <= 0 {
		resolvedActivationTTL = defaultActivationTTLForRequest(*requestTimeout)
	}

	cfg = Config{
		ListenAddr:     strings.TrimSpace(*listenAddr),
		RedisAddr:      strings.TrimSpace(*redisAddr),
		RedisPassword:  *redisPassword,
		RedisDB:        *redisDB,
		NomadAddr:      strings.TrimSpace(*nomadAddr),
		ConsulAddr:     strings.TrimSpace(*consulAddr),
		NomadToken:     strings.TrimSpace(*nomadToken),
		ConsulToken:    strings.TrimSpace(*consulToken),
		RequestTimeout: *requestTimeout,
		ActivationTTL:  resolvedActivationTTL,
		ProbePath:      normalizeProbePath(*probePath),
	}

	if cfg.ListenAddr == "" {
		return Config{}, errors.New("listen address is required")
	}
	if cfg.RedisAddr == "" {
		return Config{}, errors.New("redis address is required")
	}
	if cfg.NomadAddr == "" {
		return Config{}, errors.New("nomad address is required")
	}
	if cfg.ConsulAddr == "" {
		return Config{}, errors.New("consul address is required")
	}
	if cfg.RequestTimeout <= 0 {
		return Config{}, errors.New("request timeout must be greater than zero")
	}
	if cfg.ActivationTTL < cfg.RequestTimeout {
		return Config{}, errors.New("activation timeout must be greater than or equal to request timeout")
	}

	return cfg, nil
}

func defaultActivationTTLForRequest(requestTimeout time.Duration) time.Duration {
	if requestTimeout <= 0 {
		return defaultActivationTTL
	}

	activationTTL := requestTimeout + 45*time.Second
	if activationTTL < defaultActivationTTL {
		return defaultActivationTTL
	}
	return activationTTL
}

func writeText(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(body))
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func decodeJSONBody(body io.Reader, target any) error {
	decoder := json.NewDecoder(body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return fmt.Errorf("decode json body: %w", err)
	}
	return nil
}

func activationStatusCode(err error) int {
	switch {
	case errors.Is(err, errActivationTimeout), errors.Is(err, context.DeadlineExceeded):
		return http.StatusGatewayTimeout
	default:
		return http.StatusServiceUnavailable
	}
}

func proxyTo(rw http.ResponseWriter, req *http.Request, target *url.URL, logger *slog.Logger) {
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		logger.WarnContext(r.Context(), "reverse proxy request failed", "error", err)
		http.Error(w, fmt.Sprintf("proxy error: %v", err), http.StatusBadGateway)
	}
	proxy.Director = func(r *http.Request) {
		r.URL.Scheme = target.Scheme
		r.URL.Host = target.Host
	}
	proxy.ServeHTTP(rw, req)
}

func envOrDefault(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

func envOrDefaultDuration(key string, defaultVal time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if parsed, err := time.ParseDuration(v); err == nil {
			return parsed
		}
		if seconds, err := strconv.Atoi(v); err == nil {
			return time.Duration(seconds) * time.Second
		}
	}
	return defaultVal
}

func envOrDefaultInt(key string, defaultVal int) int {
	if v := os.Getenv(key); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil {
			return parsed
		}
	}
	return defaultVal
}

func newJSONLogger(service string) *slog.Logger {
	level := parseLogLevel(os.Getenv("LOG_LEVEL"))
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level})).With(
		"service", service,
	)
}

func parseLogLevel(raw string) slog.Level {
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
