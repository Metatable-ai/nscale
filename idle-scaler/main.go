package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	activitystore "nomad_scale_to_zero/activity-store"

	consul "github.com/hashicorp/consul/api"
	nomad "github.com/hashicorp/nomad/api"
)

const (
	metaEnabled     = "scale-to-zero.enabled"
	metaIdleTimeout = "scale-to-zero.idle-timeout"
	metaJobSpecKey  = "scale-to-zero.job-spec-kv"
)

func main() {
	var (
		nomadAddr   = flag.String("nomad-addr", envOrDefault("NOMAD_ADDR", "http://nomad.service.consul:4646"), "Nomad API address")
		consulAddr  = flag.String("consul-addr", envOrDefault("CONSUL_ADDR", "http://consul.service.consul:8500"), "Consul address")
		nomadToken  = flag.String("nomad-token", envOrDefault("NOMAD_TOKEN", ""), "Nomad ACL token")
		consulToken = flag.String("consul-token", envOrDefault("CONSUL_TOKEN", ""), "Consul ACL token")
		redisAddr   = flag.String("redis-addr", envOrDefault("REDIS_ADDR", ""), "Redis address (optional, uses Consul if empty)")
		redisPass   = flag.String("redis-password", envOrDefault("REDIS_PASSWORD", ""), "Redis password")
		redisDB     = flag.Int("redis-db", envOrDefaultInt("REDIS_DB", 0), "Redis database number")
		storeType   = flag.String("store-type", envOrDefault("STORE_TYPE", "consul"), "Store type: consul or redis")
		interval    = flag.Duration("interval", envOrDefaultDuration("IDLE_CHECK_INTERVAL", 30*time.Second), "Idle check interval")
		defaultTO   = flag.Duration("default-idle-timeout", envOrDefaultDuration("DEFAULT_IDLE_TIMEOUT", 5*time.Minute), "Default idle timeout")
		purgeOnSD   = flag.Bool("purge-on-scaledown", envOrDefaultBool("PURGE_ON_SCALEDOWN", false), "Purge job on scale down when idle")
	)
	flag.Parse()

	nomadClient, err := nomad.NewClient(&nomad.Config{Address: *nomadAddr, SecretID: *nomadToken})
	if err != nil {
		log.Fatalf("nomad client: %v", err)
	}

	if _, err := nomadClient.Status().Leader(); err != nil {
		log.Fatalf("nomad status: %v", err)
	}

	var store activitystore.Store
	var jobSpecStore activitystore.JobSpecStore

	switch *storeType {
	case "redis":
		if *redisAddr == "" {
			log.Fatalf("redis-addr is required when store-type=redis")
		}
		redisCfg := activitystore.RedisConfig{
			Addr:     *redisAddr,
			Password: *redisPass,
			DB:       *redisDB,
		}
		redisStore, err := activitystore.NewRedisStore(redisCfg, activitystore.DefaultNamespace)
		if err != nil {
			log.Fatalf("redis activity store: %v", err)
		}
		store = redisStore

		redisJobStore, err := activitystore.NewRedisJobSpecStore(redisCfg, activitystore.DefaultNamespace)
		if err != nil {
			log.Fatalf("redis job spec store: %v", err)
		}
		jobSpecStore = redisJobStore
		log.Printf("Using Redis backend at %s", *redisAddr)

	default: // consul
		consulStore, err := activitystore.NewConsulStoreWithToken(*consulAddr, *consulToken, activitystore.DefaultNamespace)
		if err != nil {
			log.Fatalf("consul activity store: %v", err)
		}
		store = consulStore

		consulConfig := consul.DefaultConfig()
		consulConfig.Address = *consulAddr
		consulConfig.Token = *consulToken
		consulClient, err := consul.NewClient(consulConfig)
		if err != nil {
			log.Fatalf("consul client: %v", err)
		}
		jobSpecStore = &ConsulJobSpecStore{client: consulClient}
		log.Printf("Using Consul backend at %s", *consulAddr)
	}

	scaler := &IdleScaler{
		nomadClient:  nomadClient,
		store:        store,
		jobSpecStore: jobSpecStore,
		interval:     *interval,
		defaultTO:    *defaultTO,
		purgeOnSD:    *purgeOnSD,
	}

	log.Printf("idle-scaler started (interval=%s, default-timeout=%s)", *interval, *defaultTO)
	ctx := context.Background()
	for {
		if err := scaler.RunOnce(ctx); err != nil {
			log.Printf("run error: %v", err)
		}
		time.Sleep(*interval)
	}
}

type IdleScaler struct {
	nomadClient  *nomad.Client
	store        activitystore.Store
	jobSpecStore activitystore.JobSpecStore
	interval     time.Duration
	defaultTO    time.Duration
	purgeOnSD    bool
}

func (s *IdleScaler) RunOnce(ctx context.Context) error {
	jobs, _, err := s.nomadClient.Jobs().List(nil)
	if err != nil {
		return fmt.Errorf("list jobs: %w", err)
	}

	for _, job := range jobs {
		jobInfo, _, err := s.nomadClient.Jobs().Info(job.ID, nil)
		if err != nil {
			return fmt.Errorf("job info %s: %w", job.ID, err)
		}
		if jobInfo == nil || jobInfo.Meta == nil {
			continue
		}

		if strings.ToLower(jobInfo.Meta[metaEnabled]) != "true" {
			continue
		}

		if err := s.storeJobSpec(jobInfo); err != nil {
			log.Printf("store job spec %s: %v", job.ID, err)
		}

		timeout := s.defaultTO
		if raw := jobInfo.Meta[metaIdleTimeout]; raw != "" {
			if parsed, err := time.ParseDuration(raw + "s"); err == nil {
				timeout = parsed
			}
		}

		if err := s.maybeScaleToZero(ctx, jobInfo, timeout); err != nil {
			return err
		}
	}

	return nil
}

func (s *IdleScaler) storeJobSpec(job *nomad.Job) error {
	if s.jobSpecStore == nil || job == nil {
		return nil
	}

	jobID := ""
	if job.ID != nil {
		jobID = *job.ID
	}
	if jobID == "" {
		return nil
	}

	// Clone the job to avoid modifying the original
	jobCopy := *job
	// Ensure Stop is false so the job can be revived
	stopFalse := false
	jobCopy.Stop = &stopFalse

	payload, err := json.Marshal(jobCopy)
	if err != nil {
		return fmt.Errorf("marshal job %s: %w", jobID, err)
	}

	// Use SetJobSpecIfChanged to avoid unnecessary writes
	changed, err := s.jobSpecStore.SetJobSpecIfChanged(jobID, payload)
	if err != nil {
		return fmt.Errorf("store job spec %s: %w", jobID, err)
	}
	if changed {
		log.Printf("job spec updated: %s", jobID)
	}

	return nil
}

func (s *IdleScaler) maybeScaleToZero(ctx context.Context, job *nomad.Job, timeout time.Duration) error {
	jobID := ""
	if job.ID != nil {
		jobID = *job.ID
	}
	if jobID == "" || job.TaskGroups == nil {
		return nil
	}

	for _, group := range job.TaskGroups {
		groupName := ""
		if group.Name != nil {
			groupName = *group.Name
		}
		if groupName == "" {
			continue
		}

		count := 0
		if group.Count != nil {
			count = *group.Count
		}
		if count == 0 {
			continue
		}

		serviceName := s.resolveServiceName(job, group)
		if serviceName == "" {
			continue
		}

		last, ok, err := s.store.LastActivity(serviceName)
		if err != nil {
			return err
		}

		if !ok {
			// No activity recorded; initialize to now to avoid immediate scale-down
			if err := s.store.SetActivity(serviceName, time.Now()); err != nil {
				return err
			}
			continue
		}

		if time.Since(last) < timeout {
			continue
		}

		log.Printf("scaling job=%s group=%s to 0 (idle %s >= %s)", jobID, groupName, time.Since(last), timeout)
		if s.purgeOnSD {
			log.Printf("purging job=%s (idle %s >= %s)", jobID, time.Since(last), timeout)
			return s.purgeJob(jobID)
		}
		if err := s.scaleGroup(jobID, groupName, 0); err != nil {
			return err
		}
	}

	return nil
}

func (s *IdleScaler) resolveServiceName(job *nomad.Job, group *nomad.TaskGroup) string {
	if group.Services != nil {
		for _, svc := range group.Services {
			if svc != nil && svc.Name != "" {
				return svc.Name
			}
		}
	}

	// fallback: use job name
	if job.Name != nil {
		return *job.Name
	}

	return ""
}

func (s *IdleScaler) scaleGroup(jobID, group string, count int64) error {
	countValue := int(count)
	_, _, err := s.nomadClient.Jobs().Scale(jobID, group, &countValue, "scale-to-zero idle", false, nil, nil)
	if err != nil {
		return fmt.Errorf("scale job %s group %s: %w", jobID, group, err)
	}

	return nil
}

func (s *IdleScaler) purgeJob(jobID string) error {
	_, _, err := s.nomadClient.Jobs().Deregister(jobID, true, nil)
	if err != nil {
		return fmt.Errorf("purge job %s: %w", jobID, err)
	}
	return nil
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

func envOrDefaultBool(key string, defaultVal bool) bool {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		switch strings.ToLower(v) {
		case "1", "true", "yes", "y", "on":
			return true
		case "0", "false", "no", "n", "off":
			return false
		}
	}
	return defaultVal
}

// ConsulJobSpecStore implements JobSpecStore using Consul KV
type ConsulJobSpecStore struct {
	client     *consul.Client
	specHashes map[string]string // in-memory cache to avoid unnecessary writes
}

func (s *ConsulJobSpecStore) key(jobID string) string {
	return "scale-to-zero/jobs/" + strings.TrimPrefix(jobID, "/")
}

func (s *ConsulJobSpecStore) GetJobSpec(jobID string) ([]byte, bool, error) {
	key := s.key(jobID)
	pair, _, err := s.client.KV().Get(key, nil)
	if err != nil {
		return nil, false, fmt.Errorf("get job spec %s: %w", key, err)
	}
	if pair == nil || len(pair.Value) == 0 {
		return nil, false, nil
	}

	// Validate JSON
	if !json.Valid(pair.Value) {
		return nil, false, fmt.Errorf("invalid JSON in job spec %s", key)
	}

	return pair.Value, true, nil
}

func (s *ConsulJobSpecStore) SetJobSpec(jobID string, spec []byte) error {
	// Validate JSON before storing
	if !json.Valid(spec) {
		return fmt.Errorf("invalid JSON for job spec %s", jobID)
	}

	key := s.key(jobID)
	_, err := s.client.KV().Put(&consul.KVPair{Key: key, Value: spec}, nil)
	if err != nil {
		return fmt.Errorf("store job spec %s: %w", key, err)
	}

	return nil
}

func (s *ConsulJobSpecStore) SetJobSpecIfChanged(jobID string, spec []byte) (bool, error) {
	// Validate JSON before storing
	if !json.Valid(spec) {
		return false, fmt.Errorf("invalid JSON for job spec %s", jobID)
	}

	// Initialize hash cache if needed
	if s.specHashes == nil {
		s.specHashes = make(map[string]string)
	}

	// Compute hash
	newHash := computeHash(spec)

	// Check if hash matches cached value
	if s.specHashes[jobID] == newHash {
		return false, nil
	}

	// Write to Consul
	key := s.key(jobID)
	_, err := s.client.KV().Put(&consul.KVPair{Key: key, Value: spec}, nil)
	if err != nil {
		return false, fmt.Errorf("store job spec %s: %w", key, err)
	}

	// Update cache
	s.specHashes[jobID] = newHash
	return true, nil
}

func (s *ConsulJobSpecStore) DeleteJobSpec(jobID string) error {
	key := s.key(jobID)
	_, err := s.client.KV().Delete(key, nil)
	if err != nil {
		return fmt.Errorf("delete job spec %s: %w", key, err)
	}
	if s.specHashes != nil {
		delete(s.specHashes, jobID)
	}
	return nil
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
