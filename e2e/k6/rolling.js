import http from 'k6/http';
import { check, sleep } from 'k6';
import { pickServiceName, requestParams, resolvedBaseUrl } from './targets.js';

const baseUrl = resolvedBaseUrl();

export const options = {
  vus: Number(__ENV.E2E_BURST_VUS || 50),
  duration: __ENV.E2E_BURST_DURATION || '20s',
  thresholds: {
    http_req_failed: ['rate<0.05'],
  },
};

export default function () {
  const serviceName = pickServiceName(__ITER);
  const res = http.get(baseUrl, requestParams(serviceName));

  check(res, {
    'rolling status is 200': (r) => r.status === 200,
  });

  sleep(Math.random());
}