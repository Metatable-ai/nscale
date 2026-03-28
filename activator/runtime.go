// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"golang.org/x/sync/singleflight"
)

const (
	readyEndpointTTL         = 30 * time.Second
	activationFailureTTL     = 10 * time.Second
	wakePollInterval         = 250 * time.Millisecond
	probeRequestTTL          = 1 * time.Second
	releaseWakeLockTTL       = 5 * time.Second
	activationStateOpTimeout = 5 * time.Second
	scaleUpReassertInterval  = 1 * time.Second
)

var errActivationTimeout = errors.New("timeout waiting for backend activation")

const (
	activationStatusPending = "pending"
	activationStatusReady   = "ready"
	activationStatusFailed  = "failed"
)

type requestRuntime interface {
	Activate(ctx context.Context, workload WorkloadRegistration) (*url.URL, error)
}

type waitForActivationTimeoutError struct {
	service string
}

func (e waitForActivationTimeoutError) Error() string {
	return fmt.Sprintf("%s for %s", errActivationTimeout, e.service)
}

func (e waitForActivationTimeoutError) Is(target error) bool {
	return target == errActivationTimeout
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
	Status     string              `json:"Status"`
	TaskGroups []nomadJobTaskGroup `json:"TaskGroups"`
}

type nomadJobTaskGroup struct {
	Name  string `json:"Name"`
	Count int    `json:"Count"`
}

type nomadAllocation struct {
	ID           string `json:"ID"`
	TaskGroup    string `json:"TaskGroup"`
	ClientStatus string `json:"ClientStatus"`
	TaskStates   map[string]struct {
		State string `json:"State"`
	} `json:"TaskStates"`
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

type nomadRuntime struct {
	logger         *slog.Logger
	store          stateStore
	client         *http.Client
	inflight       singleflight.Group
	nomadAddr      string
	consulAddr     string
	nomadToken     string
	consulToken    string
	requestTimeout time.Duration
	activationTTL  time.Duration
	probePath      string
}

func newNomadRuntime(logger *slog.Logger, store stateStore, cfg Config) *nomadRuntime {
	if logger == nil {
		logger = newJSONLogger("activator")
	}

	return &nomadRuntime{
		logger:         logger,
		store:          store,
		client:         &http.Client{Timeout: 10 * time.Second},
		nomadAddr:      strings.TrimSpace(cfg.NomadAddr),
		consulAddr:     strings.TrimSpace(cfg.ConsulAddr),
		nomadToken:     strings.TrimSpace(cfg.NomadToken),
		consulToken:    strings.TrimSpace(cfg.ConsulToken),
		requestTimeout: cfg.RequestTimeout,
		activationTTL:  cfg.ActivationTTL,
		probePath:      normalizeProbePath(cfg.ProbePath),
	}
}

func (r *nomadRuntime) Activate(ctx context.Context, workload WorkloadRegistration) (*url.URL, error) {
	logger := r.logger.With(
		"host", workload.HostName,
		"service_name", workload.ServiceName,
		"job_name", workload.JobName,
		"group_name", workload.GroupName,
	)

	if endpoint, ok, err := r.lookupReadyEndpoint(ctx, workload); err != nil {
		logger.WarnContext(ctx, "ready endpoint lookup failed", "error", err)
	} else if ok {
		return cloneURL(endpoint), nil
	}

	if endpoint, ok, err := r.lookupActivationReadyEndpoint(ctx, workload, logger); err != nil {
		logger.WarnContext(ctx, "activation state lookup failed", "error", err)
	} else if ok {
		r.cacheReadyEndpoint(ctx, workload, endpoint, logger)
		return cloneURL(endpoint), nil
	}

	if err := r.startActivation(ctx, workload, logger); err != nil {
		return nil, err
	}

	endpoint, err := r.waitForActivation(ctx, workload, logger)
	if err != nil {
		return nil, err
	}

	return cloneURL(endpoint), nil
}

func (r *nomadRuntime) startActivation(ctx context.Context, workload WorkloadRegistration, logger *slog.Logger) error {
	_, err, _ := r.inflight.Do(workload.HostName, func() (interface{}, error) {
		if endpoint, ok, err := r.lookupActivationReadyEndpoint(ctx, workload, logger); err != nil {
			logger.WarnContext(ctx, "activation state lookup failed before activation start", "error", err)
		} else if ok {
			r.cacheReadyEndpoint(ctx, workload, endpoint, logger)
			return nil, nil
		}

		if state, ok, err := r.store.GetActivationState(ctx, workload.HostName); err != nil {
			logger.WarnContext(ctx, "activation state lookup failed before wake lock acquisition", "error", err)
		} else if ok && state.Status == activationStatusPending {
			return nil, nil
		}

		startCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), activationStateOpTimeout)
		defer cancel()

		owner := fmt.Sprintf("%s-%d", workload.HostName, time.Now().UnixNano())
		acquired, err := r.store.AcquireWakeLock(startCtx, workload.HostName, owner, r.wakeLockTTL())
		if err != nil {
			return nil, fmt.Errorf("acquire wake lock: %w", err)
		}
		if !acquired {
			return nil, nil
		}

		state := ActivationState{
			Status: activationStatusPending,
			Owner:  owner,
		}
		if err := r.store.SetActivationState(startCtx, workload.HostName, state, r.wakeLockTTL()); err != nil {
			_ = r.store.ReleaseWakeLock(startCtx, workload.HostName, owner)
			return nil, fmt.Errorf("set activation pending: %w", err)
		}

		go r.runActivation(ctx, workload, owner, logger)
		return nil, nil
	})
	return err
}

func (r *nomadRuntime) runActivation(ctx context.Context, workload WorkloadRegistration, owner string, logger *slog.Logger) {
	activationCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), r.activationTTL)
	defer cancel()

	endpoint, err := r.performWake(activationCtx, workload, logger)
	state := ActivationState{
		Status: activationStatusFailed,
		Owner:  owner,
	}
	stateTTL := activationFailureTTL
	if err != nil {
		state.Error = err.Error()
		logger.WarnContext(activationCtx, "backend activation failed", "error", err)
	} else if endpoint != nil {
		state.Status = activationStatusReady
		state.Endpoint = endpoint.String()
		stateTTL = readyEndpointTTL
		logger.InfoContext(activationCtx, "backend activation ready", "target", endpoint.String())
	}

	stateCtx, stateCancel := context.WithTimeout(context.Background(), activationStateOpTimeout)
	defer stateCancel()
	if stateErr := r.store.SetActivationState(stateCtx, workload.HostName, state, stateTTL); stateErr != nil {
		logger.Warn("publish activation result failed", "error", stateErr)
	}

	releaseCtx, releaseCancel := context.WithTimeout(context.Background(), releaseWakeLockTTL)
	defer releaseCancel()
	if releaseErr := r.store.ReleaseWakeLock(releaseCtx, workload.HostName, owner); releaseErr != nil {
		logger.Warn("release wake lock failed", "error", releaseErr)
	}
}

func (r *nomadRuntime) waitForActivation(ctx context.Context, workload WorkloadRegistration, logger *slog.Logger) (*url.URL, error) {
	ticker := time.NewTicker(wakePollInterval)
	defer ticker.Stop()

	for {
		if endpoint, ok, err := r.lookupReadyEndpoint(ctx, workload); err != nil {
			logger.WarnContext(ctx, "ready endpoint lookup failed while waiting for activation", "error", err)
		} else if ok {
			return endpoint, nil
		}

		state, ok, err := r.store.GetActivationState(ctx, workload.HostName)
		if err != nil {
			logger.WarnContext(ctx, "activation state lookup failed while waiting", "error", err)
		} else if ok {
			switch state.Status {
			case activationStatusReady:
				endpoint, ready, parseErr := state.ReadyEndpoint()
				if parseErr != nil {
					logger.WarnContext(ctx, "activation state ready endpoint parse failed", "error", parseErr)
					return nil, parseErr
				}
				if ready {
					r.cacheReadyEndpoint(ctx, workload, endpoint, logger)
					return endpoint, nil
				}
			case activationStatusFailed:
				if state.Error == "" {
					return nil, errors.New("activation failed")
				}
				return nil, errors.New(state.Error)
			}
		} else if err := r.startActivation(ctx, workload, logger); err != nil {
			return nil, err
		}

		select {
		case <-ctx.Done():
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				return nil, waitForActivationTimeoutError{service: workload.ServiceName}
			}
			return nil, ctx.Err()
		case <-ticker.C:
		}
	}
}

func (r *nomadRuntime) lookupActivationReadyEndpoint(ctx context.Context, workload WorkloadRegistration, logger *slog.Logger) (*url.URL, bool, error) {
	state, ok, err := r.store.GetActivationState(ctx, workload.HostName)
	if err != nil || !ok || state.Status != activationStatusReady {
		return nil, false, err
	}

	endpoint, ready, err := state.ReadyEndpoint()
	if err != nil || !ready {
		return nil, false, err
	}
	if !r.probeEndpointHealth(ctx, endpoint) {
		clearCtx, cancel := context.WithTimeout(context.Background(), activationStateOpTimeout)
		defer cancel()
		if clearErr := r.store.ClearActivationState(clearCtx, workload.HostName); clearErr != nil {
			logger.Warn("clear stale activation state failed", "error", clearErr)
		}
		return nil, false, nil
	}

	return endpoint, true, nil
}

func (r *nomadRuntime) performWake(ctx context.Context, workload WorkloadRegistration, logger *slog.Logger) (*url.URL, error) {
	if endpoint, healthy, err := r.resolveHealthyEndpoint(ctx, workload); err != nil {
		logger.WarnContext(ctx, "consul health check failed under activator wake lock", "error", err)
	} else if healthy {
		r.cacheReadyEndpoint(ctx, workload, endpoint, logger)
		return endpoint, nil
	}

	if err := r.ensureJob(ctx, workload); err != nil {
		return nil, fmt.Errorf("ensure job: %w", err)
	}

	if err := r.scaleUp(ctx, workload.JobName, workload.GroupName); err != nil {
		endpoint, waitErr := r.waitForNomadAllocation(ctx, workload.JobName, workload.GroupName)
		if waitErr == nil {
			r.cacheReadyEndpoint(ctx, workload, endpoint, logger)
			return endpoint, nil
		}
		return nil, fmt.Errorf("scale up: %w", err)
	}

	endpoint, err := r.waitForNomadAllocation(ctx, workload.JobName, workload.GroupName)
	if err != nil {
		return nil, fmt.Errorf("wait allocation: %w", err)
	}

	r.cacheReadyEndpoint(ctx, workload, endpoint, logger)
	return endpoint, nil
}

func (r *nomadRuntime) lookupReadyEndpoint(ctx context.Context, workload WorkloadRegistration) (*url.URL, bool, error) {
	endpoint, ok, err := r.store.LookupReadyEndpoint(ctx, workload.HostName)
	if err != nil || !ok {
		return nil, ok, err
	}
	if !r.probeEndpointHealth(ctx, endpoint) {
		if clearErr := r.store.ClearReadyEndpoint(ctx, workload.HostName); clearErr != nil {
			r.logger.WarnContext(ctx, "clear stale ready endpoint failed", "host", workload.HostName, "error", clearErr)
		}
		return nil, false, nil
	}
	return endpoint, true, nil
}

func (r *nomadRuntime) cacheReadyEndpoint(ctx context.Context, workload WorkloadRegistration, endpoint *url.URL, logger *slog.Logger) {
	if endpoint == nil {
		return
	}
	if err := r.store.SetReadyEndpoint(ctx, workload.HostName, endpoint, readyEndpointTTL); err != nil {
		logger.WarnContext(ctx, "cache ready endpoint failed", "error", err, "target", endpoint.String())
	}
}

func (r *nomadRuntime) wakeLockTTL() time.Duration {
	return r.activationTTL + 15*time.Second
}

func (r *nomadRuntime) resolveHealthyEndpoint(ctx context.Context, workload WorkloadRegistration) (*url.URL, bool, error) {
	endpoint, healthy, err := r.getHealthyEndpoint(ctx, workload.ServiceName)
	if err != nil || !healthy {
		return nil, false, err
	}

	count, err := r.getJobGroupCount(ctx, workload.JobName, workload.GroupName)
	if err != nil {
		return nil, false, err
	}
	if count == 0 {
		return nil, false, nil
	}
	if !r.probeEndpointHealth(ctx, endpoint) {
		return nil, false, nil
	}

	return endpoint, true, nil
}

func (r *nomadRuntime) getHealthyEndpoint(ctx context.Context, service string) (*url.URL, bool, error) {
	endpoint := fmt.Sprintf("%s/v1/health/service/%s?passing=1", r.consulAddr, url.PathEscape(service))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, false, err
	}
	r.addConsulToken(req)

	resp, err := r.client.Do(req)
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

	return &url.URL{Scheme: "http", Host: fmt.Sprintf("%s:%d", addr, entries[0].Service.Port)}, true, nil
}

func (r *nomadRuntime) ensureJob(ctx context.Context, workload WorkloadRegistration) error {
	status, err := r.jobStatus(ctx, workload.JobName)
	if err != nil {
		return err
	}
	if status != "not-found" && status != "stopped" {
		return nil
	}

	spec, found, err := r.store.GetJobSpec(ctx, workload.JobSpecKey)
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("job spec not found at %s", workload.JobSpecKey)
	}

	payload, err := wrapJobRegister(spec)
	if err != nil {
		return err
	}

	endpoint := fmt.Sprintf("%s/v1/jobs", r.nomadAddr)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	r.addNomadToken(req)

	resp, err := r.client.Do(req)
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

func (r *nomadRuntime) jobStatus(ctx context.Context, job string) (string, error) {
	endpoint := fmt.Sprintf("%s/v1/job/%s", r.nomadAddr, url.PathEscape(job))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return "", err
	}
	r.addNomadToken(req)

	resp, err := r.client.Do(req)
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

	if _, ok := obj["Job"]; ok {
		var wrapper struct {
			Job map[string]interface{} `json:"Job"`
		}
		if err := json.Unmarshal(raw, &wrapper); err != nil {
			return nil, err
		}
		wrapper.Job["Stop"] = false
		return json.Marshal(wrapper)
	}

	var jobObj map[string]interface{}
	if err := json.Unmarshal(raw, &jobObj); err != nil {
		return nil, err
	}
	jobObj["Stop"] = false

	return json.Marshal(map[string]interface{}{"Job": jobObj})
}

func (r *nomadRuntime) scaleUp(ctx context.Context, job, group string) error {
	payload := map[string]interface{}{
		"Count":  1,
		"Target": map[string]string{"Group": group},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	endpoint := fmt.Sprintf("%s/v1/job/%s/scale", r.nomadAddr, url.PathEscape(job))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	r.addNomadToken(req)

	resp, err := r.client.Do(req)
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

func (r *nomadRuntime) getJobGroupCount(ctx context.Context, job, group string) (int, error) {
	endpoint := fmt.Sprintf("%s/v1/job/%s", r.nomadAddr, url.PathEscape(job))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return -1, err
	}
	r.addNomadToken(req)

	resp, err := r.client.Do(req)
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

func (r *nomadRuntime) getNomadAllocations(ctx context.Context, job string) ([]nomadAllocation, error) {
	endpoint := fmt.Sprintf("%s/v1/job/%s/allocations?resources=true", r.nomadAddr, url.PathEscape(job))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	r.addNomadToken(req)

	resp, err := r.client.Do(req)
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

func (r *nomadRuntime) getNomadAllocation(ctx context.Context, allocID string) (*nomadAllocation, error) {
	endpoint := fmt.Sprintf("%s/v1/allocation/%s", r.nomadAddr, url.PathEscape(allocID))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	r.addNomadToken(req)

	resp, err := r.client.Do(req)
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

func (r *nomadRuntime) waitForNomadAllocation(ctx context.Context, job, group string) (*url.URL, error) {
	startedAt := time.Now()
	logger := r.logger.With("job", job, "group", group)
	timer := time.NewTimer(0)
	defer timer.Stop()
	lastScaleUpAt := startedAt

	for {
		if err := ctx.Err(); err != nil {
			if errors.Is(err, context.DeadlineExceeded) {
				return nil, waitForActivationTimeoutError{service: job + "/" + group}
			}
			return nil, err
		}

		allocs, err := r.getNomadAllocations(ctx, job)
		if err != nil {
			return nil, err
		}

		sawActiveAllocation := false
		for _, alloc := range allocs {
			if alloc.TaskGroup != group {
				continue
			}
			if alloc.ClientStatus == "pending" || alloc.ClientStatus == "running" {
				sawActiveAllocation = true
			}
			if alloc.ClientStatus != "running" {
				continue
			}

			allTasksRunning := len(alloc.TaskStates) > 0
			for _, state := range alloc.TaskStates {
				if state.State != "running" {
					allTasksRunning = false
					break
				}
			}
			if !allTasksRunning {
				continue
			}

			endpoint := extractAllocEndpoint(alloc)
			if endpoint == nil {
				fullAlloc, err := r.getNomadAllocation(ctx, alloc.ID)
				if err != nil {
					logger.WarnContext(ctx, "failed to fetch full allocation", "alloc_id", shortAllocID(alloc.ID), "error", err)
					continue
				}
				endpoint = extractAllocEndpoint(*fullAlloc)
			}
			if endpoint == nil {
				logger.WarnContext(ctx, "allocation running but no network endpoint found", "alloc_id", shortAllocID(alloc.ID))
				continue
			}
			if r.probeEndpointHealth(ctx, endpoint) {
				logger.InfoContext(ctx, "nomad allocation healthy", "alloc_id", shortAllocID(alloc.ID), "target", endpoint.String())
				return endpoint, nil
			}
		}
		if !sawActiveAllocation {
			reasserted, err := r.reassertScaleUpIfNeeded(ctx, job, group, logger, lastScaleUpAt)
			if err != nil {
				return nil, err
			}
			if reasserted {
				lastScaleUpAt = time.Now()
			}
		}

		elapsed := time.Since(startedAt)
		var pollInterval time.Duration
		switch {
		case elapsed < 5*time.Second:
			pollInterval = 500 * time.Millisecond
		case elapsed < 15*time.Second:
			pollInterval = 1 * time.Second
		default:
			pollInterval = 2 * time.Second
		}

		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		timer.Reset(pollInterval)

		select {
		case <-ctx.Done():
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				return nil, waitForActivationTimeoutError{service: job + "/" + group}
			}
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
}

func (r *nomadRuntime) reassertScaleUpIfNeeded(ctx context.Context, job, group string, logger *slog.Logger, lastScaleUpAt time.Time) (bool, error) {
	if !lastScaleUpAt.IsZero() && time.Since(lastScaleUpAt) < scaleUpReassertInterval {
		return false, nil
	}

	count, err := r.getJobGroupCount(ctx, job, group)
	if err != nil {
		return false, err
	}
	if count > 0 {
		return false, nil
	}

	if err := r.scaleUp(ctx, job, group); err != nil {
		return false, err
	}

	logger.InfoContext(ctx, "reasserted nomad scale up while waiting for allocation", "target_count", 1)
	return true, nil
}

func extractAllocEndpoint(alloc nomadAllocation) *url.URL {
	if alloc.AllocatedResources != nil {
		for _, network := range alloc.AllocatedResources.Shared.Networks {
			if endpoint := firstPort(network); endpoint != nil {
				return endpoint
			}
		}
		for _, network := range alloc.AllocatedResources.Networks {
			if endpoint := firstPort(network); endpoint != nil {
				return endpoint
			}
		}
	}

	for _, network := range alloc.Resources.Networks {
		if endpoint := firstPort(network); endpoint != nil {
			return endpoint
		}
	}

	return nil
}

func firstPort(network nomadAllocNetwork) *url.URL {
	if network.IP == "" {
		return nil
	}

	for _, port := range network.DynamicPorts {
		if port.Value > 0 {
			return &url.URL{Scheme: "http", Host: fmt.Sprintf("%s:%d", network.IP, port.Value)}
		}
	}
	for _, port := range network.ReservedPorts {
		if port.Value > 0 {
			return &url.URL{Scheme: "http", Host: fmt.Sprintf("%s:%d", network.IP, port.Value)}
		}
	}
	return nil
}

func (r *nomadRuntime) probeEndpointHealth(ctx context.Context, endpoint *url.URL) bool {
	if endpoint == nil {
		return false
	}

	probeURL := endpoint.ResolveReference(&url.URL{Path: normalizeProbePath(r.probePath)}).String()
	probeCtx, cancel := context.WithTimeout(ctx, probeRequestTTL)
	defer cancel()

	req, err := http.NewRequestWithContext(probeCtx, http.MethodGet, probeURL, nil)
	if err != nil {
		return false
	}

	resp, err := r.client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)

	return resp.StatusCode >= 200 && resp.StatusCode < 400
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

func shortAllocID(allocID string) string {
	if len(allocID) <= 8 {
		return allocID
	}
	return allocID[:8]
}

func cloneURL(raw *url.URL) *url.URL {
	if raw == nil {
		return nil
	}
	cloned := *raw
	return &cloned
}

func (r *nomadRuntime) addNomadToken(req *http.Request) {
	if r.nomadToken != "" {
		req.Header.Set("X-Nomad-Token", r.nomadToken)
	}
}

func (r *nomadRuntime) addConsulToken(req *http.Request) {
	if r.consulToken != "" {
		req.Header.Set("X-Consul-Token", r.consulToken)
	}
}
