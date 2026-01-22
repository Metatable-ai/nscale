// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0

package activitystore

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	JobSpecPrefix = "jobs/"
)

// JobSpecStore stores and retrieves Nomad job specs
type JobSpecStore interface {
	GetJobSpec(jobID string) ([]byte, bool, error)
	SetJobSpec(jobID string, spec []byte) error
	SetJobSpecIfChanged(jobID string, spec []byte) (changed bool, err error)
	DeleteJobSpec(jobID string) error
}

// RedisJobSpecStore stores job specs in Redis with change detection
type RedisJobSpecStore struct {
	client *redis.Client
	prefix string
}

func NewRedisJobSpecStore(cfg RedisConfig, namespace string) (*RedisJobSpecStore, error) {
	client := redis.NewClient(&redis.Options{
		Addr:     cfg.Addr,
		Password: cfg.Password,
		DB:       cfg.DB,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := client.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("redis ping: %w", err)
	}

	if namespace == "" {
		namespace = DefaultNamespace
	}

	prefix := strings.TrimSuffix(namespace, "/") + "/" + JobSpecPrefix

	return &RedisJobSpecStore{
		client: client,
		prefix: prefix,
	}, nil
}

func (s *RedisJobSpecStore) GetJobSpec(jobID string) ([]byte, bool, error) {
	ctx := context.Background()
	key := s.key(jobID)

	val, err := s.client.Get(ctx, key).Result()
	if err == redis.Nil {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("get job spec %s: %w", key, err)
	}

	// Validate JSON
	if !json.Valid([]byte(val)) {
		return nil, false, fmt.Errorf("invalid JSON in job spec %s", key)
	}

	return []byte(val), true, nil
}

func (s *RedisJobSpecStore) SetJobSpec(jobID string, spec []byte) error {
	// Validate JSON before storing
	if !json.Valid(spec) {
		return fmt.Errorf("invalid JSON for job spec %s", jobID)
	}

	ctx := context.Background()
	key := s.key(jobID)

	if err := s.client.Set(ctx, key, string(spec), 0).Err(); err != nil {
		return fmt.Errorf("set job spec %s: %w", key, err)
	}

	return nil
}

// SetJobSpecIfChanged only writes if the spec has changed (reduces writes)
func (s *RedisJobSpecStore) SetJobSpecIfChanged(jobID string, spec []byte) (bool, error) {
	// Validate JSON before storing
	if !json.Valid(spec) {
		return false, fmt.Errorf("invalid JSON for job spec %s", jobID)
	}

	ctx := context.Background()
	key := s.key(jobID)
	hashKey := key + ":hash"

	// Compute hash of new spec
	newHash := computeHash(spec)

	// Get existing hash
	existingHash, err := s.client.Get(ctx, hashKey).Result()
	if err != nil && err != redis.Nil {
		return false, fmt.Errorf("get hash %s: %w", hashKey, err)
	}

	// Skip write if hash matches
	if existingHash == newHash {
		return false, nil
	}

	// Use pipeline to update both atomically
	pipe := s.client.Pipeline()
	pipe.Set(ctx, key, string(spec), 0)
	pipe.Set(ctx, hashKey, newHash, 0)
	_, err = pipe.Exec(ctx)
	if err != nil {
		return false, fmt.Errorf("set job spec %s: %w", key, err)
	}

	return true, nil
}

func (s *RedisJobSpecStore) DeleteJobSpec(jobID string) error {
	ctx := context.Background()
	key := s.key(jobID)
	hashKey := key + ":hash"

	if err := s.client.Del(ctx, key, hashKey).Err(); err != nil {
		return fmt.Errorf("delete job spec %s: %w", key, err)
	}

	return nil
}

func (s *RedisJobSpecStore) key(jobID string) string {
	jobID = strings.TrimPrefix(jobID, "/")
	return s.prefix + jobID
}

func (s *RedisJobSpecStore) Close() error {
	return s.client.Close()
}

func computeHash(data []byte) string {
	// Use FNV-1a for speed (not cryptographic, just for change detection)
	var hash uint64 = 14695981039346656037
	for _, b := range data {
		hash ^= uint64(b)
		hash *= 1099511628211
	}
	return fmt.Sprintf("%016x", hash)
}
