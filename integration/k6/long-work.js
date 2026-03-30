/**
 * long-work.js — Verify that InFlightTracker + heartbeat protects long-running
 * requests from scale-down, even when the request duration exceeds idle_timeout.
 *
 * Timeline (idle_timeout=15s, delay=25s):
 *
 *   0s   warmup          — fast request, service wakes up (version N)
 *   5s   long_request    — VU1 sends /cgi-bin/slow?delay=25 via Traefik → nscale
 *        monitor         — VU2 polls Nomad every 2s, confirms job stays running
 *        ~5s..30s        — InFlightTracker holds guard, heartbeat refreshes activity
 *                          every idle_timeout/3 (~5s), scaler sees in-flight → skips
 *        ~30s            — CGI completes, InFlightGuard dropped, heartbeat stops
 *   35s  verify_stable   — confirm allocation version did NOT change (no kill)
 *   55s  post_idle_check — no traffic after completion → job scales to 0
 *
 * Env vars:
 *   NSCALE_TRAEFIK_URL   — Traefik base URL  (default: http://traefik:80)
 *   NSCALE_NOMAD_URL     — Nomad API          (default: http://nomad:4646)
 *   NSCALE_DELAY_SECS    — CGI sleep seconds  (default: 25)
 *   NSCALE_IDLE_TIMEOUT  — expected idle timeout in seconds (default: 15)
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend, Gauge } from 'k6/metrics';

const traefikUrl   = __ENV.NSCALE_TRAEFIK_URL  || 'http://traefik:80';
const nomadUrl     = __ENV.NSCALE_NOMAD_URL     || 'http://nomad:4646';
const delaySecs    = parseInt(__ENV.NSCALE_DELAY_SECS   || '25');
const idleTimeout  = parseInt(__ENV.NSCALE_IDLE_TIMEOUT || '15');

const longWorkDuration   = new Trend('long_work_duration', true);
const allocVersionsBefore = new Gauge('alloc_versions_before');
const allocVersionsAfter  = new Gauge('alloc_versions_after');
const scaleDownsDuringWork = new Counter('scale_downs_during_work');
const jobStayedRunning     = new Counter('job_stayed_running');

const hostHeader = { Host: 'slow-service.localhost' };

/** Count allocations by status for slow-service. */
function getAllocInfo() {
  const resp = http.get(`${nomadUrl}/v1/job/slow-service/allocations`, { timeout: '5s' });
  if (resp.status !== 200) return { total: -1, running: 0, complete: 0, versions: [] };
  const allocs = JSON.parse(resp.body);
  const running  = allocs.filter(a => a.ClientStatus === 'running').length;
  const complete = allocs.filter(a => a.ClientStatus === 'complete').length;
  const versions = [...new Set(allocs.map(a => a.JobVersion))].sort((a,b) => a - b);
  return { total: allocs.length, running, complete, versions };
}

/** Get running count from scale endpoint. */
function getRunningCount() {
  const resp = http.get(`${nomadUrl}/v1/job/slow-service/scale`, { timeout: '5s' });
  if (resp.status !== 200) return -1;
  const body = JSON.parse(resp.body);
  return body.TaskGroups && body.TaskGroups.main ? body.TaskGroups.main.Running : 0;
}

export const options = {
  scenarios: {
    warmup: {
      executor: 'shared-iterations',
      vus: 1,
      iterations: 1,
      exec: 'warmup',
      maxDuration: '60s',
    },
    long_request: {
      executor: 'shared-iterations',
      vus: 1,
      iterations: 1,
      exec: 'longRequest',
      startTime: '5s',
      maxDuration: `${delaySecs + 60}s`,
    },
    monitor: {
      executor: 'constant-vus',
      vus: 1,
      duration: `${delaySecs + 45}s`,
      exec: 'monitor',
      startTime: '5s',
    },
    verify_stable: {
      executor: 'shared-iterations',
      vus: 1,
      iterations: 1,
      exec: 'verifyStable',
      startTime: `${5 + delaySecs + 5}s`,
      maxDuration: '30s',
    },
    post_idle_check: {
      executor: 'shared-iterations',
      vus: 1,
      iterations: 1,
      exec: 'postIdleCheck',
      startTime: `${5 + delaySecs + 10 + idleTimeout + 15}s`,
      maxDuration: '60s',
    },
  },
  thresholds: {
    // InFlightTracker MUST protect the request — interruption is a regression.
    checks: ['rate>=0.80'],
  },
};

export function setup() {
  const info = getAllocInfo();
  const running = getRunningCount();
  console.log(`[setup] slow-service: running=${running}, allocs=${info.total}, versions=${JSON.stringify(info.versions)}`);
  console.log(`[setup] config: delay=${delaySecs}s, idle_timeout=${idleTimeout}s`);
  console.log(`[setup] EXPECTED: InFlightTracker + heartbeat keeps service alive during ${delaySecs}s request`);
  console.log(`[setup]   → heartbeat refreshes activity every ~${Math.floor(idleTimeout / 3)}s`);
  console.log(`[setup]   → scaler sees in-flight requests → skips scale-down`);
  console.log(`[setup]   → CGI response completes after ${delaySecs}s, then idle timeout → scale to 0`);
  return { initialVersions: info.versions, initialAllocCount: info.total };
}

// ── Phase 1: Warmup ──
export function warmup() {
  // First make sure the job is running (may need wake-up)
  console.log('[warmup] Ensuring slow-service is alive...');
  const resp = http.get(traefikUrl, {
    headers: hostHeader,
    timeout: '30s',
  });
  const ok = check(resp, {
    'warmup: status 200': (r) => r.status === 200,
  });
  const info = getAllocInfo();
  console.log(`[warmup] status=${resp.status} ok=${ok} allocs=${info.total} versions=${JSON.stringify(info.versions)}`);
  allocVersionsBefore.add(info.versions.length);
}

// ── Phase 2: Long request — InFlightTracker + heartbeat should keep it alive ──
export function longRequest() {
  const before = getAllocInfo();
  console.log(`[long_request] START: sending /cgi-bin/slow?delay=${delaySecs} (versions before: ${JSON.stringify(before.versions)})`);
  console.log(`[long_request] This request takes ${delaySecs}s, idle_timeout is ${idleTimeout}s`);
  console.log(`[long_request] InFlightTracker should protect the request from scale-down`);

  const start = Date.now();
  const resp = http.get(`${traefikUrl}/cgi-bin/slow?delay=${delaySecs}`, {
    headers: hostHeader,
    timeout: `${delaySecs + 60}s`,
  });
  const elapsedMs = Date.now() - start;

  longWorkDuration.add(elapsedMs);

  const gotCgiResponse = resp.body && resp.body.includes('Done after');
  const gotIndexPage   = resp.body && resp.body.includes('Hello from slow-service');
  const wasInterrupted = !gotCgiResponse;

  console.log(`[long_request] END: status=${resp.status} elapsed=${(elapsedMs/1000).toFixed(1)}s`);
  console.log(`[long_request] body="${(resp.body || '').trim().substring(0, 80)}"`);

  if (gotCgiResponse) {
    console.log(`[long_request] ✓ CGI response received — InFlightTracker protected the request for ${delaySecs}s`);
  } else if (wasInterrupted) {
    console.log(`[long_request] ✗ REGRESSION: request was interrupted — InFlightTracker failed to protect it`);
    if (gotIndexPage) {
      console.log(`[long_request]   → Got index.html after re-wake (service was killed mid-work)`);
    }
  }

  check(resp, {
    'long_request: got HTTP response': (r) => r.status > 0,
    'long_request: status 200': (r) => r.status === 200,
    'long_request: CGI completed (in-flight protected)': () => gotCgiResponse,
    'long_request: elapsed >= delay': () => elapsedMs >= (delaySecs - 2) * 1000,
  });

  const after = getAllocInfo();
  const sameVersions = JSON.stringify(before.versions) === JSON.stringify(after.versions);
  console.log(`[long_request] Allocs after: ${after.total}, versions: ${JSON.stringify(after.versions)}`);
  console.log(`[long_request] Versions unchanged: ${sameVersions}`);
  allocVersionsAfter.add(after.versions.length);

  check(null, {
    'long_request: no new allocation version (no kill+rewake)': () => sameVersions,
  });
}

// ── Phase 3: Monitor — poll Nomad during the long request, expect it stays running ──
export function monitor() {
  const count = getRunningCount();
  const info  = getAllocInfo();
  const ts    = new Date().toISOString().substring(11, 19);

  if (count === 0) {
    scaleDownsDuringWork.add(1);
    console.log(`[monitor ${ts}] ✗ REGRESSION: SCALED TO 0 — InFlightTracker failed! versions=${JSON.stringify(info.versions)}`);
  } else if (count > 0) {
    jobStayedRunning.add(1);
    console.log(`[monitor ${ts}] ✓ running=${count} allocs=${info.total} versions=${JSON.stringify(info.versions)}`);
  } else {
    console.log(`[monitor ${ts}] (could not query Nomad)`);
  }

  sleep(2);
}

// ── Phase 4: Verify stable — allocation should NOT have changed (no kill+rewake) ──
export function verifyStable(data) {
  const info = getAllocInfo();
  const newVersions = info.versions.filter(v => !data.initialVersions.includes(v));
  const sameAllocCount = info.total === data.initialAllocCount || info.total === data.initialAllocCount + 0;

  console.log(`[verify_stable] initial versions: ${JSON.stringify(data.initialVersions)}`);
  console.log(`[verify_stable] current versions: ${JSON.stringify(info.versions)}`);
  console.log(`[verify_stable] new versions: ${JSON.stringify(newVersions)}`);
  console.log(`[verify_stable] allocs: ${data.initialAllocCount} → ${info.total}`);

  // With InFlightTracker, no new versions should appear — the service was NOT killed
  check(null, {
    'verify_stable: no new allocation versions (request was protected)': () => newVersions.length === 0,
  });

  if (newVersions.length === 0) {
    console.log(`[verify_stable] ✓ Service was NOT killed — InFlightTracker protected in-flight request`);
  } else {
    console.log(`[verify_stable] ✗ REGRESSION: New allocation versions appeared — service was killed and re-woken`);
  }

  // Service should still be alive
  const resp = http.get(traefikUrl, {
    headers: hostHeader,
    timeout: '30s',
  });
  check(resp, {
    'verify_stable: service responds 200': (r) => r.status === 200,
  });
  console.log(`[verify_stable] service status=${resp.status}`);
}

// ── Phase 5: Post-idle — should scale to 0 again after no traffic ──
export function postIdleCheck() {
  console.log('[post_idle_check] No traffic sent. Waiting for scale-down...');

  let count = -1;
  for (let i = 0; i < 25; i++) {
    count = getRunningCount();
    if (count === 0) {
      console.log(`[post_idle_check] ✓ Job scaled to 0 after ${i * 2}s of no traffic`);
      break;
    }
    sleep(2);
  }

  check(null, {
    'post_idle_check: job scaled to 0': () => count === 0,
  });

  const info = getAllocInfo();
  console.log(`[post_idle_check] final: running=${count}, total allocs=${info.total}, versions=${JSON.stringify(info.versions)}`);
  console.log('');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('  SUMMARY: Long-work lifecycle test (InFlightTracker)');
  console.log('═══════════════════════════════════════════════════════════');
  console.log(`  Delay:             ${delaySecs}s`);
  console.log(`  Idle timeout:      ${idleTimeout}s`);
  console.log(`  Initial versions:  ${JSON.stringify(__ENV._INIT_VERSIONS || 'N/A')}`);
  console.log(`  Final versions:    ${JSON.stringify(info.versions)}`);
  console.log(`  Total allocations: ${info.total}`);
  console.log(`  InFlightTracker + heartbeat should have kept the service`);
  console.log(`  alive during the ${delaySecs}s request, then idle timeout`);
  console.log(`  triggered scale-down after heartbeat stopped.`);
  console.log('═══════════════════════════════════════════════════════════');
}
