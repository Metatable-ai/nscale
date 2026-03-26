import http from 'k6/http';
import { check } from 'k6';
import { pickServiceName, requestParams, resolvedBaseUrl } from './targets.js';

export const options = {
  scenarios: {
    cold_start_storm: {
      executor: 'ramping-arrival-rate',
      startRate: Number(__ENV.E2E_STORM_START_RATE || 25),
      timeUnit: '1s',
      preAllocatedVUs: Number(__ENV.E2E_STORM_PREALLOCATED_VUS || 150),
      maxVUs: Number(__ENV.E2E_STORM_MAX_VUS || 400),
      stages: [
        { target: Number(__ENV.E2E_STORM_RATE || 250), duration: __ENV.E2E_STORM_DURATION || '30s' },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<45000'],
  },
};

const baseUrl = resolvedBaseUrl();

export default function () {
  const serviceName = pickServiceName(__ITER);
  const res = http.get(baseUrl, requestParams(serviceName));

  check(res, {
    'storm status is 200': (r) => r.status === 200,
  });
}