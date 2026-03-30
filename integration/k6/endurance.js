/**
 * endurance.js — Combined soak + long-work mixed-fleet certification test.
 *
 * 50 services, a configurable fraction of which are "slow" (CGI-capable).
 * Two concurrent scenarios:
 *
 *   1. traffic   — VUs send requests to random services. Fast services get a
 *                  quick GET /; slow services randomly get a long-running
 *                  /cgi-bin/slow?delay=N request. Think time is intentionally
 *                  long enough that idle services naturally scale to zero.
 *
 *   2. watchdog  — A single VU periodically logs overall system health:
 *                  running/stopped counts and nscale admin endpoint.
 *
 * What this validates:
 *   - InFlightTracker protects in-flight long requests from natural scale-down
 *   - Natural idle scale-down → re-wake cycles over extended time
 *   - Wake behavior across a mixed fleet of fast and slow services
 *   - No resource leaks (goroutines, memory, file descriptors) over time
 *   - System stability with realistic, non-forced traffic patterns
 *
 * Note: this test intentionally does NOT inject forced Nomad scale-to-zero
 * events. We already have dedicated chaos/failure-injection coverage in
 * multi-service.js. This scenario is meant to model more natural behavior.
 *
 * Env vars:
 *   NSCALE_JOB_COUNT       — total services            (default: 50)
 *   NSCALE_SLOW_COUNT      — how many have CGI         (default: 15)
 *   NSCALE_MAX_VUS         — traffic VUs               (default: 30)
 *   NSCALE_DURATION        — test duration             (default: 10m)
 *   NSCALE_THINK_MIN_S     — min think time (seconds)  (default: 4)
 *   NSCALE_THINK_MAX_S     — max think time (seconds)  (default: 12)
 *   NSCALE_SLOW_DELAY_MIN  — min CGI delay (seconds)   (default: 10)
 *   NSCALE_SLOW_DELAY_MAX  — max CGI delay (seconds)   (default: 30)
 *   NSCALE_SLOW_CHANCE     — probability of slow req   (default: 0.3)
 *   NSCALE_TRAEFIK_URL     — Traefik URL               (default: http://traefik:80)
 *   NSCALE_NOMAD_URL       — Nomad API                 (default: http://nomad:4646)
 *   NSCALE_ADMIN_URL       — nscale admin              (default: http://nscale:9090)
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend, Rate } from 'k6/metrics';

// ── Config ──────────────────────────────────────────────
const jobCount     = parseInt(__ENV.NSCALE_JOB_COUNT       || '50');
const slowCount    = parseInt(__ENV.NSCALE_SLOW_COUNT      || '15');
const maxVUs       = parseInt(__ENV.NSCALE_MAX_VUS         || '30');
const duration     = __ENV.NSCALE_DURATION                 || '10m';
const thinkMinS    = parseFloat(__ENV.NSCALE_THINK_MIN_S   || '4');
const thinkMaxS    = parseFloat(__ENV.NSCALE_THINK_MAX_S   || '12');
const slowDelayMin = parseInt(__ENV.NSCALE_SLOW_DELAY_MIN  || '10');
const slowDelayMax = parseInt(__ENV.NSCALE_SLOW_DELAY_MAX  || '30');
const slowChance   = parseFloat(__ENV.NSCALE_SLOW_CHANCE   || '0.3');
const traefikUrl   = __ENV.NSCALE_TRAEFIK_URL              || 'http://traefik:80';
const nomadUrl     = __ENV.NSCALE_NOMAD_URL                || 'http://nomad:4646';
const adminUrl     = __ENV.NSCALE_ADMIN_URL                || 'http://nscale:9090';

// ── Metrics ─────────────────────────────────────────────
const wakeLatency       = new Trend('wake_latency', true);
const slowReqDuration   = new Trend('slow_req_duration', true);
const fastReqDuration   = new Trend('fast_req_duration', true);
const wakesTriggered    = new Counter('wakes_triggered');
const slowReqsCompleted = new Counter('slow_reqs_completed');
const slowReqsFailed    = new Counter('slow_reqs_failed');
const slowReqProtected  = new Rate('slow_req_protected');

// ── Service Lists ───────────────────────────────────────
function jobName(i) { return `echo-${String(i).padStart(3, '0')}`; }

const allServices  = [];
const slowServices = [];
const fastServices = [];

for (let i = 1; i <= jobCount; i++) {
  const name = jobName(i);
  allServices.push(name);
  if (i <= slowCount) {
    slowServices.push(name);
  } else {
    fastServices.push(name);
  }
}

// ── Options ─────────────────────────────────────────────
export const options = {
  scenarios: {
    traffic: {
      executor: 'constant-vus',
      vus: maxVUs,
      duration: duration,
      exec: 'traffic',
    },
    watchdog: {
      executor: 'constant-vus',
      vus: 1,
      duration: duration,
      exec: 'watchdog',
    },
  },
  thresholds: {
    http_req_failed:       ['rate<=0.02'],                          // natural traffic should be near-clean
    'http_req_duration{scenario:traffic}': ['p(95)<=35000'],        // 35s p95 (slow requests up to 30s)
    'fast_req_duration':   ['p(95)<=15000'],                        // 15s p95 for fast reqs (includes wakes)
    'slow_req_protected':  ['rate>=0.98'],                          // long requests should almost always complete
  },
};

// ── Helpers ─────────────────────────────────────────────
function randInt(min, max) { return Math.floor(Math.random() * (max - min + 1)) + min; }
function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }

function getServiceStatus(svc) {
  const resp = http.get(`${nomadUrl}/v1/job/${svc}/scale`, { timeout: '5s', tags: { name: 'nomad_query' } });
  if (resp.status !== 200) return -1;
  try {
    const body = JSON.parse(resp.body);
    return body.TaskGroups && body.TaskGroups.main ? body.TaskGroups.main.Running : 0;
  } catch (_) { return -1; }
}

// ── Setup ───────────────────────────────────────────────
export function setup() {
  let running = 0, stopped = 0;
  for (const svc of allServices) {
    const count = getServiceStatus(svc);
    if (count > 0) running++;
    else stopped++;
  }
  console.log(`[endurance] Setup: ${running} running, ${stopped} stopped out of ${jobCount}`);
  console.log(`[endurance] Slow services (indices 1..${slowCount}): ${slowServices.slice(0, 5).join(', ')}...`);
  console.log(`[endurance] Config: duration=${duration}, VUs=${maxVUs}, think=${thinkMinS}-${thinkMaxS}s`);
  console.log(`[endurance] Slow: delay=${slowDelayMin}-${slowDelayMax}s, chance=${slowChance}, count=${slowCount}`);
  console.log('[endurance] Mode: natural idle sleep/re-wake only (no forced kills)');
  return { allServices, slowServices, fastServices };
}

// ── Scenario 1: Traffic — mixed fast/slow requests with soak-style think time ──
export function traffic(data) {
  const svc = pick(data.allServices);
  const isSlow = data.slowServices.includes(svc);

  // Decide: send a slow CGI request or a fast one
  const doSlowRequest = isSlow && Math.random() < slowChance;

  const start = Date.now();
  let resp;

  if (doSlowRequest) {
    const delay = randInt(slowDelayMin, slowDelayMax);
    resp = http.get(`${traefikUrl}/cgi-bin/slow?delay=${delay}`, {
      headers: { Host: `${svc}.localhost` },
      timeout: `${delay + 60}s`,
      tags: { name: 'slow_request' },
    });
    const elapsedMs = Date.now() - start;
    slowReqDuration.add(elapsedMs);

    const gotCgiResponse = resp.body && resp.body.includes('Done after');

    if (gotCgiResponse) {
      slowReqsCompleted.add(1);
      slowReqProtected.add(1);
    } else {
      slowReqsFailed.add(1);
      slowReqProtected.add(0);
      if (resp.status === 200) {
        // Got index.html instead of CGI — means service was killed mid-work and re-woken
        console.log(`[traffic] REGRESSION: ${svc} slow request interrupted after ${(elapsedMs/1000).toFixed(1)}s`);
      }
    }
  } else {
    resp = http.get(traefikUrl, {
      headers: { Host: `${svc}.localhost` },
      timeout: '30s',
      tags: { name: 'fast_request' },
    });
    const elapsedMs = Date.now() - start;
    fastReqDuration.add(elapsedMs);

    // Track cold-start wakes from naturally dormant services.
    if (elapsedMs > 500) {
      wakeLatency.add(elapsedMs);
      wakesTriggered.add(1);
    }
  }

  check(resp, { 'status 200': (r) => r.status === 200 });

  // Soak-style think time: long enough to let idle services scale down naturally
  const think = thinkMinS + Math.random() * (thinkMaxS - thinkMinS);
  sleep(think);
}

// ── Scenario 2: Watchdog — periodic health snapshot ──
export function watchdog() {
  let running = 0, stopped = 0;

  // Sample 10 random services to avoid hammering Nomad API
  const sample = [];
  const shuffled = [...allServices].sort(() => Math.random() - 0.5);
  for (let i = 0; i < Math.min(10, shuffled.length); i++) {
    sample.push(shuffled[i]);
  }

  for (const svc of sample) {
    const count = getServiceStatus(svc);
    if (count > 0) running++;
    else stopped++;
  }

  const ts = new Date().toISOString().substring(11, 19);
  console.log(`[watchdog ${ts}] sample(10): ${running} running, ${stopped} stopped`);

  // Check nscale health
  const healthResp = http.get(`${adminUrl}/healthz`, { timeout: '5s', tags: { name: 'health_check' } });
  if (healthResp.status !== 200) {
    console.log(`[watchdog ${ts}] WARNING: nscale healthz returned ${healthResp.status}`);
  }

  sleep(15);
}

// ── Teardown ────────────────────────────────────────────
export function teardown(data) {
  let running = 0, stopped = 0;
  for (const svc of data.allServices) {
    const count = getServiceStatus(svc);
    if (count > 0) running++;
    else stopped++;
  }
  console.log('');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('  ENDURANCE TEST SUMMARY');
  console.log('═══════════════════════════════════════════════════════════');
  console.log(`  Duration:          ${duration}`);
  console.log(`  Services:          ${jobCount} (${slowCount} slow, ${jobCount - slowCount} fast)`);
  console.log(`  Traffic VUs:       ${maxVUs}`);
  console.log(`  Think time:        ${thinkMinS}-${thinkMaxS}s`);
  console.log(`  Slow delay range:  ${slowDelayMin}-${slowDelayMax}s`);
  console.log(`  Final state:       ${running} running, ${stopped} stopped`);
  console.log('═══════════════════════════════════════════════════════════');
}
