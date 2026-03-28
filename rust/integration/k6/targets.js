// Shared configuration for nscale stress tests.
//
// All env vars prefixed with NSCALE_ to avoid collision with existing e2e vars.

const baseUrl   = __ENV.NSCALE_TRAEFIK_URL || 'http://traefik:80';
const nomadUrl  = __ENV.NSCALE_NOMAD_URL   || 'http://nomad:4646';
const consulUrl = __ENV.NSCALE_CONSUL_URL  || 'http://consul:8500';
const svcName   = __ENV.NSCALE_SERVICE_NAME  || 'echo-s2z';
const svcGroup  = __ENV.NSCALE_NOMAD_GROUP   || 'main';

export function resolvedBaseUrl()    { return baseUrl;   }
export function resolvedNomadUrl()   { return nomadUrl;  }
export function resolvedConsulUrl()  { return consulUrl; }
export function resolvedServiceName(){ return svcName;   }
export function resolvedNomadGroup() { return svcGroup;  }

/** Returns Traefik request params (Host header + timeout). */
export function requestParams() {
  return {
    headers: { Host: `${svcName}.localhost` },
    timeout: '30s',
  };
}

/**
 * Thresholds for each test type.
 *   load   — warm path, tight latency
 *   wake   — cold-start path, generous latency
 */
export function stressThresholds() {
  return {
    loadP95Ms:      parseInt(__ENV.NSCALE_LOAD_P95_MS      || '500'),
    wakeP95Ms:      parseInt(__ENV.NSCALE_WAKE_P95_MS      || '15000'),
    wakeP99Ms:      parseInt(__ENV.NSCALE_WAKE_P99_MS      || '25000'),
    maxFailureRate: parseFloat(__ENV.NSCALE_MAX_FAILURE_RATE || '0.02'),
  };
}
