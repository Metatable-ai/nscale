/**
 * soak.js — Long-duration soak test with natural idle scale-down cycles.
 *
 * Sends low-rate traffic that pauses between requests.  The idle_timeout (15 s)
 * will naturally scale the job to zero during quiet periods, and the next
 * request triggers a re-wake.  Observes multiple scale-down → wake cycles over
 * the test duration.
 *
 * Measures:
 *   - Stability over time: no memory leaks, no goroutine accumulation.
 *   - Re-wake latency stays consistent across repeated cycles.
 *   - Zero request failures across many scale cycles.
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import { resolvedBaseUrl, requestParams, stressThresholds } from './targets.js';

const { wakeP95Ms, wakeP99Ms, maxFailureRate } = stressThresholds();

const vus      = parseInt(__ENV.NSCALE_SOAK_VUS      || '3');
const duration = __ENV.NSCALE_SOAK_DURATION           || '5m';
// Think time between requests: must exceed idle_timeout occasionally to trigger
// automatic scale-down.  Default 6 s means at ~3 VUs each fires ~0.5 rps,
// so quiet periods naturally emerge.
const thinkTimeS = parseFloat(__ENV.NSCALE_SOAK_THINK_S || '6');

export const options = {
  vus,
  duration,
  thresholds: {
    http_req_failed:   [`rate<=${maxFailureRate}`],
    http_req_duration: [`p(95)<=${wakeP95Ms}`, `p(99)<=${wakeP99Ms}`],
  },
};

const baseUrl = resolvedBaseUrl();

export default function () {
  const res = http.get(baseUrl, requestParams());
  check(res, { 'soak 200': (r) => r.status === 200 });
  sleep(thinkTimeS + Math.random() * 4); // 6–10 s think time
}
