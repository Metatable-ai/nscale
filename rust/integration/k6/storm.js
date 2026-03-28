/**
 * storm.js — High-rate cold-start burst using ramping-arrival-rate.
 *
 * setup()   : scales the job to 0, waits for Consul deregistration.
 * default() : sends requests at an escalating arrival rate to a dormant service.
 *
 * Measures:
 *   - WakeCoordinator concurrency: 1 scale-up fires, all queued requests unblock.
 *   - Latency distribution under high concurrency (p95 / p99 cold-start).
 *   - Failure rate — any 5xx during the burst is captured.
 *
 * After the first wake succeeds, Traefik's ConsulCatalog route comes alive and
 * subsequent requests bypass nscale, so the sustain stage measures warm-path
 * throughput at the same arrival rate.
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import {
  resolvedBaseUrl, resolvedNomadUrl, resolvedConsulUrl,
  resolvedServiceName, resolvedNomadGroup, requestParams, stressThresholds,
} from './targets.js';

const { wakeP95Ms, wakeP99Ms, maxFailureRate } = stressThresholds();

const startRate      = parseInt(__ENV.NSCALE_STORM_START_RATE        || '1');
const peakRate       = parseInt(__ENV.NSCALE_STORM_RATE              || '30');
const rampDuration   = __ENV.NSCALE_STORM_RAMP_DURATION              || '30s';
const sustainDuration= __ENV.NSCALE_STORM_SUSTAIN_DURATION           || '30s';
const preAllocated   = parseInt(__ENV.NSCALE_STORM_PREALLOCATED_VUS  || '60');
const maxVUs         = parseInt(__ENV.NSCALE_STORM_MAX_VUS           || '200');

export const options = {
  scenarios: {
    cold_start_storm: {
      executor: 'ramping-arrival-rate',
      startRate,
      timeUnit: '1s',
      preAllocatedVUs: preAllocated,
      maxVUs,
      stages: [
        { target: peakRate, duration: rampDuration    }, // ramp to peak
        { target: peakRate, duration: sustainDuration }, // sustain
        { target: 0,        duration: '10s'           }, // cool-down
      ],
    },
  },
  thresholds: {
    http_req_failed:   [`rate<=${maxFailureRate}`],
    http_req_duration: [`p(95)<=${wakeP95Ms}`, `p(99)<=${wakeP99Ms}`],
  },
};

export function setup() {
  const nomadUrl  = resolvedNomadUrl();
  const consulUrl = resolvedConsulUrl();
  const svcName   = resolvedServiceName();
  const group     = resolvedNomadGroup();

  console.log(`[storm] Scaling ${svcName} to 0 before storm...`);
  const scaleResp = http.post(
    `${nomadUrl}/v1/job/${svcName}/scale`,
    JSON.stringify({ Count: 0, Target: { Group: group } }),
    { headers: { 'Content-Type': 'application/json' }, timeout: '10s' },
  );
  if (scaleResp.status < 200 || scaleResp.status >= 300) {
    console.error(`[storm] Scale-down failed: HTTP ${scaleResp.status}`);
  }

  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    const health = http.get(
      `${consulUrl}/v1/health/service/${svcName}?passing=true`,
      { timeout: '5s' },
    );
    if (JSON.parse(health.body || '[]').length === 0) {
      console.log(`[storm] ${svcName} is dormant — unleashing storm`);
      return;
    }
    sleep(1);
  }
  console.warn('[storm] Service still healthy after 20s — storm may not hit a cold target');
}

const baseUrl = resolvedBaseUrl();

export default function () {
  const res = http.get(baseUrl, requestParams());
  check(res, { 'storm 200': (r) => r.status === 200 });
}
