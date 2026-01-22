package activitystore

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

type RedisStore struct {
	client *redis.Client
	prefix string
}

type RedisConfig struct {
	Addr     string
	Password string
	DB       int
}

func NewRedisStore(cfg RedisConfig, namespace string) (*RedisStore, error) {
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

	prefix := strings.TrimSuffix(namespace, "/") + "/" + ActivityPrefix

	return &RedisStore{
		client: client,
		prefix: prefix,
	}, nil
}

func (s *RedisStore) LastActivity(service string) (time.Time, bool, error) {
	ctx := context.Background()
	key := s.key(service)

	val, err := s.client.Get(ctx, key).Result()
	if err == redis.Nil {
		return time.Time{}, false, nil
	}
	if err != nil {
		return time.Time{}, false, fmt.Errorf("get activity %s: %w", key, err)
	}

	parsed, err := time.Parse(time.RFC3339Nano, val)
	if err != nil {
		return time.Time{}, false, fmt.Errorf("parse activity %s: %w", key, err)
	}

	return parsed, true, nil
}

func (s *RedisStore) SetActivity(service string, at time.Time) error {
	ctx := context.Background()
	key := s.key(service)
	val := at.UTC().Format(time.RFC3339Nano)

	if err := s.client.Set(ctx, key, val, 0).Err(); err != nil {
		return fmt.Errorf("set activity %s: %w", key, err)
	}

	return nil
}

func (s *RedisStore) key(service string) string {
	service = strings.TrimPrefix(service, "/")
	return s.prefix + service
}

func (s *RedisStore) Close() error {
	return s.client.Close()
}
