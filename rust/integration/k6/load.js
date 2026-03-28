/**
 * load.js — Sustained warm-path ramp test.
 *
 * The job stays warm during this test.  Measures steady-state throughput and
 * latency when Traefik routes directly via ConsulCatalog (bypassing nscale).
 *
 * Stages: ramp-up → sustain → ramp-down
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import { resolvedBaseUrl, requestParams, stressThresholds } from './targets.js';

const { loadP95Ms, maxFailureRate } = stressThresholds();

const maxVUs           = parseInt(__ENV.NSCALE_MAX_VUS            || '20');
const rampUpDuration   = __ENV.NSCALE_RAMPUP_DURATION             || '20s';
const sustainDuration  = __ENV.NSCALE_SUSTAIN_DURATION            || '60s';
const rampDownDuration = __ENV.NSCALE_RAMPDOWN_DURATION           || '20s';

export const options = {
  stages: [
    { duration: rampUpDuration,   target: maxVUs },
    { duration: sustainDuration,  target: maxVUs },
    { duration: rampDownDuration, target: 0 },
  ],
  thresholds: {
    http_req_failed:   [`rate<=${maxFailureRate}`],
    http_req_duration: [`p(95)<=${loadP95Ms}`],
  },
};

const baseUrl = resolvedBaseUrl();

export default function () {
  const res = http.get(baseUrl, requestParams());
  check(res, { 'load 200': (r) => r.status === 200 });
  sleep(Math.random() * 0.5); // 0–500 ms think time
}
