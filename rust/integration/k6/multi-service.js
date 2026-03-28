/**
 * multi-service.js — Stress test with N concurrent services + random kills.
 *
 * Two scenarios run in parallel:
 *   1. multi_traffic — VUs send requests to random services via Traefik.
 *   2. chaos_killer  — A single VU periodically scales random jobs to 0,
 *      forcing cold-start wake-ups when traffic VUs hit them next.
 *
 * This tests:
 *   - Wake-up latency under concurrent multi-service load
 *   - Traffic probe correctly protecting active services
 *   - nscale's ability to handle many simultaneous cold starts
 *
 * Env vars:
 *   NSCALE_JOB_COUNT      — number of services (default: 50)
 *   NSCALE_MAX_VUS        — max traffic VUs (default: 50)
 *   NSCALE_DURATION       — test duration (default: 90s)
 *   NSCALE_KILL_INTERVAL  — seconds between random kills (default: 5)
 *   NSCALE_KILL_BATCH     — how many jobs to kill per interval (default: 3)
 *   NSCALE_TRAEFIK_URL    — Traefik base URL (default: http://traefik:80)
 *   NSCALE_NOMAD_URL      — Nomad API (default: http://nomad:4646)
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const jobCount     = parseInt(__ENV.NSCALE_JOB_COUNT     || '50');
const maxVUs       = parseInt(__ENV.NSCALE_MAX_VUS       || '50');
const duration     = __ENV.NSCALE_DURATION               || '90s';
const killInterval = parseInt(__ENV.NSCALE_KILL_INTERVAL || '5');
const killBatch    = parseInt(__ENV.NSCALE_KILL_BATCH    || '3');
const traefikUrl   = __ENV.NSCALE_TRAEFIK_URL            || 'http://traefik:80';
const nomadUrl     = __ENV.NSCALE_NOMAD_URL              || 'http://nomad:4646';

const wakeLatency  = new Trend('wake_latency', true);
const wakesTriggered = new Counter('wakes_triggered');
const killsPerformed = new Counter('kills_performed');

// Generate service names: echo-001..echo-050
function jobName(i) {
  return `echo-${String(i).padStart(3, '0')}`;
}

const services = [];
for (let i = 1; i <= jobCount; i++) {
  services.push(jobName(i));
}

export const options = {
  scenarios: {
    multi_traffic: {
      executor: 'constant-vus',
      vus: maxVUs,
      duration: duration,
      exec: 'traffic',
    },
    chaos_killer: {
      executor: 'constant-vus',
      vus: 1,
      duration: duration,
      exec: 'chaos',
    },
  },
  thresholds: {
    http_req_failed:   ['rate<=0.10'],    // 10% budget — cold starts may 502 briefly
    'http_req_duration{scenario:multi_traffic}': ['p(95)<=15000'], // 15s p95 with wakes
  },
};

export function setup() {
  // Verify all jobs are running
  let running = 0;
  let stopped = 0;
  for (const svc of services) {
    const resp = http.get(`${nomadUrl}/v1/job/${svc}/scale`, { timeout: '5s' });
    if (resp.status === 200) {
      const body = JSON.parse(resp.body);
      const count = body.TaskGroups && body.TaskGroups.main ? body.TaskGroups.main.Running : 0;
      if (count > 0) running++;
      else stopped++;
    }
  }
  console.log(`[multi] Setup: ${running} running, ${stopped} stopped out of ${jobCount}`);
  console.log(`[multi] Chaos: killing ${killBatch} random jobs every ${killInterval}s`);
  return { services };
}

// ── Scenario 1: Traffic VUs ──
export function traffic(data) {
  const svc = data.services[Math.floor(Math.random() * data.services.length)];

  const start = Date.now();
  const res = http.get(traefikUrl, {
    headers: { Host: `${svc}.localhost` },
    timeout: '30s',
    tags: { name: 'multi_request' },
  });
  const elapsed = Date.now() - start;

  check(res, { 'status 200': (r) => r.status === 200 });

  // Track cold-start wake latency (responses > 500ms are likely wakes)
  if (elapsed > 500) {
    wakeLatency.add(elapsed);
    wakesTriggered.add(1);
  }

  sleep(Math.random() * 0.3);
}

// ── Scenario 2: Chaos Killer VU ──
export function chaos(data) {
  // Pick random services to kill
  const targets = [];
  const available = [...data.services];
  for (let i = 0; i < killBatch && available.length > 0; i++) {
    const idx = Math.floor(Math.random() * available.length);
    targets.push(available.splice(idx, 1)[0]);
  }

  for (const svc of targets) {
    const resp = http.post(
      `${nomadUrl}/v1/job/${svc}/scale`,
      JSON.stringify({ Count: 0, Target: { Group: 'main' } }),
      {
        headers: { 'Content-Type': 'application/json' },
        timeout: '10s',
        tags: { name: 'chaos_kill' },
      },
    );
    if (resp.status >= 200 && resp.status < 300) {
      killsPerformed.add(1);
      console.log(`[chaos] killed ${svc}`);
    }
  }

  sleep(killInterval);
}

export function teardown(data) {
  let running = 0;
  let stopped = 0;
  for (const svc of data.services) {
    const resp = http.get(`${nomadUrl}/v1/job/${svc}/scale`, { timeout: '5s' });
    if (resp.status === 200) {
      const body = JSON.parse(resp.body);
      const count = body.TaskGroups && body.TaskGroups.main ? body.TaskGroups.main.Running : 0;
      if (count > 0) running++;
      else stopped++;
    }
  }
  console.log(`[multi] Teardown: ${running} running, ${stopped} stopped`);
}
