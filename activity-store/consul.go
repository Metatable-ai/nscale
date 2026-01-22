// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0

package activitystore

import (
	"fmt"
	"strings"
	"time"

	consul "github.com/hashicorp/consul/api"
)

type ConsulStore struct {
	client *consul.Client
	prefix string
}

func NewConsulStore(address string, namespace string) (*ConsulStore, error) {
	return NewConsulStoreWithToken(address, "", namespace)
}

func NewConsulStoreWithToken(address, token, namespace string) (*ConsulStore, error) {
	config := consul.DefaultConfig()
	if address != "" {
		config.Address = address
	}
	if token != "" {
		config.Token = token
	}

	client, err := consul.NewClient(config)
	if err != nil {
		return nil, err
	}

	if namespace == "" {
		namespace = DefaultNamespace
	}

	prefix := strings.TrimSuffix(namespace, "/") + "/" + ActivityPrefix

	return &ConsulStore{
		client: client,
		prefix: prefix,
	}, nil
}

func (s *ConsulStore) LastActivity(service string) (time.Time, bool, error) {
	key := s.key(service)
	pair, _, err := s.client.KV().Get(key, nil)
	if err != nil {
		return time.Time{}, false, fmt.Errorf("get activity %s: %w", key, err)
	}
	if pair == nil || len(pair.Value) == 0 {
		return time.Time{}, false, nil
	}

	parsed, err := time.Parse(time.RFC3339Nano, string(pair.Value))
	if err != nil {
		return time.Time{}, false, fmt.Errorf("parse activity %s: %w", key, err)
	}

	return parsed, true, nil
}

func (s *ConsulStore) SetActivity(service string, at time.Time) error {
	key := s.key(service)
	pair := &consul.KVPair{
		Key:   key,
		Value: []byte(at.UTC().Format(time.RFC3339Nano)),
	}

	_, err := s.client.KV().Put(pair, nil)
	if err != nil {
		return fmt.Errorf("set activity %s: %w", key, err)
	}

	return nil
}

func (s *ConsulStore) key(service string) string {
	service = strings.TrimPrefix(service, "/")
	return s.prefix + service
}
