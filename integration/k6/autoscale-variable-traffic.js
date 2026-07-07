import http from 'k6/http';
import { check, sleep } from 'k6';
import { resolvedBaseUrl, requestParams } from './targets.js';

const lowRate = parseInt(__ENV.NSCALE_AUTOSCALE_LOW_RATE || '1');
const highRate = parseInt(__ENV.NSCALE_AUTOSCALE_HIGH_RATE || '12');
const lowDuration = __ENV.NSCALE_AUTOSCALE_LOW_DURATION || '20s';
const highDuration = __ENV.NSCALE_AUTOSCALE_HIGH_DURATION || '60s';
const cooldownDuration = __ENV.NSCALE_AUTOSCALE_COOLDOWN_DURATION || '60s';
const requestPath = __ENV.NSCALE_REQUEST_PATH || '/';

export const options = {
  scenarios: {
    variable_traffic: {
      executor: 'ramping-arrival-rate',
      startRate: lowRate,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 150,
      stages: [
        { target: lowRate, duration: lowDuration },
        { target: highRate, duration: highDuration },
        { target: lowRate, duration: cooldownDuration },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<=0.02'],
  },
};

const baseUrl = resolvedBaseUrl();

export default function () {
  const res = http.get(`${baseUrl}${requestPath}`, requestParams());
  check(res, { 'autoscale variable 200': (r) => r.status === 200 });
  sleep(Math.random() * 0.1);
}
