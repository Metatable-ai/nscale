/**
 * coldstart.js — Concurrent cold-start probes.
 *
 * setup()   : scales the job to 0 and waits until Consul shows 0 healthy.
 * default() : N VUs each fire a single request — all arrive at a dormant service.
 *
 * Measures:
 *   - Wake deduplication under concurrent load (all N should succeed, only
 *     1 actual Nomad scale-up call is made by the WakeCoordinator).
 *   - End-to-end cold-start latency seen by the first wave of clients.
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import {
  resolvedBaseUrl, resolvedNomadUrl, resolvedConsulUrl,
  resolvedServiceName, resolvedNomadGroup, requestParams, stressThresholds,
} from './targets.js';

const { wakeP95Ms, wakeP99Ms, maxFailureRate } = stressThresholds();
const vus = parseInt(__ENV.NSCALE_COLDSTART_VUS || '10');

export const options = {
  scenarios: {
    cold_start_probe: {
      executor: 'per-vu-iterations',
      vus: vus,
      iterations: 1,
      maxDuration: '60s',
      gracefulStop: '0s',
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

  console.log(`[coldstart] Scaling ${svcName} to 0...`);
  const scaleResp = http.post(
    `${nomadUrl}/v1/job/${svcName}/scale`,
    JSON.stringify({ Count: 0, Target: { Group: group } }),
    { headers: { 'Content-Type': 'application/json' }, timeout: '10s' },
  );
  if (scaleResp.status < 200 || scaleResp.status >= 300) {
    console.error(`[coldstart] Scale-down failed: HTTP ${scaleResp.status} ${scaleResp.body}`);
  }

  // Wait up to 20s for Consul to show 0 healthy instances.
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    const health = http.get(
      `${consulUrl}/v1/health/service/${svcName}?passing=true`,
      { timeout: '5s' },
    );
    const instances = JSON.parse(health.body || '[]');
    if (instances.length === 0) {
      console.log(`[coldstart] ${svcName} is dormant — starting probes`);
      return;
    }
    sleep(1);
  }
  console.warn('[coldstart] Service still healthy after 20s wait — probes may not measure cold-start');
}

const baseUrl = resolvedBaseUrl();

export default function () {
  const res = http.get(baseUrl, requestParams());
  check(res, { 'cold-start 200': (r) => r.status === 200 });
}
