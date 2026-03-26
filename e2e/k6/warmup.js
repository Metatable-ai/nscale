import http from 'k6/http';
import { check, sleep } from 'k6';
import { pickServiceName, requestParams, resolvedBaseUrl } from './targets.js';

export const options = {
  vus: Number(__ENV.E2E_WARMUP_VUS || 5),
  duration: __ENV.E2E_WARMUP_DURATION || '10s',
};

const baseUrl = resolvedBaseUrl();

export default function () {
  const serviceName = pickServiceName(__ITER);
  const res = http.get(baseUrl, requestParams(serviceName));

  check(res, {
    'warmup status is 200': (r) => r.status === 200,
  });

  sleep(1);
}