# Activity Store

Provides a simple interface for recording and reading last activity timestamps and job specs.

## Backends

### Consul KV

Uses Consul KV with RFC3339Nano timestamps.

Key format:
```
scale-to-zero/activity/<service-name>
scale-to-zero/jobs/<job-id>
```

### Redis

Uses Redis for better write performance in high-volume environments.

Key format:
```
scale-to-zero/activity/<service-name>
scale-to-zero/jobs/<job-id>
scale-to-zero/jobs/<job-id>:hash  # Change detection hash
```

## Usage

```go
// Consul backend
store, err := activitystore.NewConsulStore("http://localhost:8500", "scale-to-zero")

// Redis backend
redisCfg := activitystore.RedisConfig{
    Addr:     "localhost:6379",
    Password: "",
    DB:       0,
}
store, err := activitystore.NewRedisStore(redisCfg, "scale-to-zero")

// Job spec storage (Redis with change detection)
jobStore, err := activitystore.NewRedisJobSpecStore(redisCfg, "scale-to-zero")
changed, err := jobStore.SetJobSpecIfChanged("my-job", specJSON)
```

## Performance Considerations

- **Consul**: Good for small deployments. Uses Raft consensus - high write volume can cause leader pressure.
- **Redis**: Better for large deployments (100+ jobs). Single-threaded but very fast for KV operations.

For large-scale deployments, use Redis for activity tracking and job spec storage to reduce Consul Raft pressure.
