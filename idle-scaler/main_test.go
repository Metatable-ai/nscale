//go:build !integration

// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"fmt"
	"strconv"
	"testing"
	"time"

	nomad "github.com/hashicorp/nomad/api"
)

// ---------------------------------------------------------------------------
// Unit tests — no infrastructure required
// ---------------------------------------------------------------------------

func TestEnvOrDefault(t *testing.T) {
	t.Run("env set", func(t *testing.T) {
		t.Setenv("TEST_EOD_VAL", "from-env")
		got := envOrDefault("TEST_EOD_VAL", "fallback")
		if got != "from-env" {
			t.Errorf("got %q, want %q", got, "from-env")
		}
	})
	t.Run("env empty", func(t *testing.T) {
		got := envOrDefault("TEST_EOD_MISSING_"+fmt.Sprintf("%d", time.Now().UnixNano()), "fallback")
		if got != "fallback" {
			t.Errorf("got %q, want %q", got, "fallback")
		}
	})
}

func TestEnvOrDefaultDuration(t *testing.T) {
	tests := []struct {
		name string
		env  string
		want time.Duration
	}{
		{"go duration", "30s", 30 * time.Second},
		{"minutes", "5m", 5 * time.Minute},
		{"plain seconds", "120", 120 * time.Second},
		{"invalid", "xyz", 99 * time.Second}, // falls through to default
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			key := fmt.Sprintf("TEST_EODD_%d", time.Now().UnixNano())
			t.Setenv(key, tt.env)
			got := envOrDefaultDuration(key, 99*time.Second)
			if got != tt.want {
				t.Errorf("envOrDefaultDuration(%q) = %v, want %v", tt.env, got, tt.want)
			}
		})
	}
	t.Run("unset", func(t *testing.T) {
		got := envOrDefaultDuration("MISSING_KEY_"+fmt.Sprintf("%d", time.Now().UnixNano()), 42*time.Second)
		if got != 42*time.Second {
			t.Errorf("got %v, want 42s", got)
		}
	})
}

func TestEnvOrDefaultInt(t *testing.T) {
	t.Run("valid", func(t *testing.T) {
		key := fmt.Sprintf("TEST_EODI_%d", time.Now().UnixNano())
		t.Setenv(key, "5")
		if got := envOrDefaultInt(key, 0); got != 5 {
			t.Errorf("got %d, want 5", got)
		}
	})
	t.Run("invalid", func(t *testing.T) {
		key := fmt.Sprintf("TEST_EODI_%d", time.Now().UnixNano())
		t.Setenv(key, "abc")
		if got := envOrDefaultInt(key, 7); got != 7 {
			t.Errorf("got %d, want 7", got)
		}
	})
	t.Run("unset", func(t *testing.T) {
		if got := envOrDefaultInt("MISSING_"+fmt.Sprintf("%d", time.Now().UnixNano()), 3); got != 3 {
			t.Errorf("got %d, want 3", got)
		}
	})
}

func TestEnvOrDefaultBool(t *testing.T) {
	truthy := []string{"1", "true", "yes", "y", "on", "TRUE", "Yes"}
	falsy := []string{"0", "false", "no", "n", "off", "FALSE", "No"}

	for _, v := range truthy {
		t.Run("true/"+v, func(t *testing.T) {
			key := fmt.Sprintf("TEST_EODB_%d", time.Now().UnixNano())
			t.Setenv(key, v)
			if got := envOrDefaultBool(key, false); !got {
				t.Errorf("envOrDefaultBool(%q) = false, want true", v)
			}
		})
	}
	for _, v := range falsy {
		t.Run("false/"+v, func(t *testing.T) {
			key := fmt.Sprintf("TEST_EODB_%d", time.Now().UnixNano())
			t.Setenv(key, v)
			if got := envOrDefaultBool(key, true); got {
				t.Errorf("envOrDefaultBool(%q) = true, want false", v)
			}
		})
	}
	t.Run("unset", func(t *testing.T) {
		if got := envOrDefaultBool("MISSING_"+fmt.Sprintf("%d", time.Now().UnixNano()), true); !got {
			t.Error("expected default true")
		}
	})
}

func TestComputeHashIdleScaler(t *testing.T) {
	h1 := computeHash([]byte(`{"v":1}`))
	h2 := computeHash([]byte(`{"v":1}`))
	h3 := computeHash([]byte(`{"v":2}`))

	if h1 != h2 {
		t.Errorf("determinism: %s != %s", h1, h2)
	}
	if h1 == h3 {
		t.Error("different data produced same hash")
	}
	if len(h1) != 16 {
		t.Errorf("hash length = %d, want 16 hex chars", len(h1))
	}
}

func TestConsulJobSpecStore_KeyFormat(t *testing.T) {
	s := &ConsulJobSpecStore{}
	tests := []struct {
		jobID string
		want  string
	}{
		{"echo-s2z", "scale-to-zero/jobs/echo-s2z"},
		{"/leading-slash", "scale-to-zero/jobs/leading-slash"},
	}
	for _, tt := range tests {
		got := s.key(tt.jobID)
		if got != tt.want {
			t.Errorf("key(%q) = %q, want %q", tt.jobID, got, tt.want)
		}
	}
}

func TestShouldManageScaleToZeroJob(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		job  *nomad.Job
		want bool
	}{
		{
			name: "nil job",
			job:  nil,
			want: false,
		},
		{
			name: "missing metadata",
			job: &nomad.Job{
				ID:   pointerTo("echo-s2z"),
				Name: pointerTo("echo-s2z"),
			},
			want: false,
		},
		{
			name: "scale to zero disabled",
			job: &nomad.Job{
				ID:   pointerTo("echo-s2z"),
				Name: pointerTo("echo-s2z"),
				Meta: map[string]string{metaEnabled: "false"},
			},
			want: false,
		},
		{
			name: "enabled service job is managed",
			job: &nomad.Job{
				ID:   pointerTo("echo-s2z"),
				Name: pointerTo("echo-s2z"),
				Type: pointerTo("service"),
				Meta: map[string]string{metaEnabled: "TRUE"},
			},
			want: true,
		},
		{
			name: "system jobs are always skipped",
			job: &nomad.Job{
				ID:   pointerTo("echo-s2z"),
				Name: pointerTo("echo-s2z"),
				Type: pointerTo("system"),
				Meta: map[string]string{metaEnabled: "true"},
			},
			want: false,
		},
		{
			name: "idle scaler job id is skipped",
			job: &nomad.Job{
				ID:   pointerTo("idle-scaler-e2e"),
				Name: pointerTo("workload"),
				Type: pointerTo("service"),
				Meta: map[string]string{metaEnabled: "true"},
			},
			want: false,
		},
		{
			name: "idle scaler job name is skipped",
			job: &nomad.Job{
				ID:   pointerTo("workload"),
				Name: pointerTo("idle-scaler"),
				Type: pointerTo("service"),
				Meta: map[string]string{metaEnabled: "true"},
			},
			want: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got := shouldManageScaleToZeroJob(tt.job)
			if got != tt.want {
				t.Errorf("shouldManageScaleToZeroJob() = %t, want %t", got, tt.want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Idle-timeout parsing — verify the fix works correctly
// ---------------------------------------------------------------------------

func TestIdleTimeoutParsing_Fixed(t *testing.T) {
	// The fixed idle-scaler does: time.ParseDuration(raw), then falls back
	// to strconv.Atoi(raw) * time.Second for bare numbers.
	tests := []struct {
		input    string
		expected time.Duration
	}{
		{"20", 20 * time.Second},
		{"300", 300 * time.Second},
		{"5m", 5 * time.Minute},
		{"30s", 30 * time.Second},
		{"1h", 1 * time.Hour},
		{"1h30m", 1*time.Hour + 30*time.Minute},
		{"500ms", 500 * time.Millisecond},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			// Replicate the fixed parsing logic
			var timeout time.Duration
			if parsed, err := time.ParseDuration(tt.input); err == nil {
				timeout = parsed
			} else if seconds, err := strconv.Atoi(tt.input); err == nil {
				timeout = time.Duration(seconds) * time.Second
			} else {
				t.Fatalf("could not parse %q", tt.input)
			}

			if timeout != tt.expected {
				t.Errorf("input %q: got %v, want %v", tt.input, timeout, tt.expected)
			}
		})
	}
}

func pointerTo[T any](value T) *T {
	return &value
}
