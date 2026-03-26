const baseUrl = __ENV.E2E_TRAEFIK_PUBLIC_URL || __ENV.E2E_TRAEFIK_BASE_URL || 'http://traefik:80';
const serviceCount = Number(__ENV.E2E_JOB_COUNT || 10);
const fixedServiceName = __ENV.E2E_K6_SERVICE_NAME || '';
const targetMode = __ENV.E2E_K6_TARGET_MODE || (fixedServiceName ? 'fixed' : 'random');

function serviceNameFromNumber(serviceNumber) {
  return `echo-s2z-${String(serviceNumber).padStart(4, '0')}`;
}

export function selectedTargetMode() {
  return targetMode;
}

export function resolvedBaseUrl() {
  return baseUrl;
}

export function pickServiceName(iteration = 0) {
  if (targetMode === 'fixed' && fixedServiceName) {
    return fixedServiceName;
  }

  if (targetMode === 'round-robin') {
    return serviceNameFromNumber((iteration % serviceCount) + 1);
  }

  const serviceNumber = Math.floor(Math.random() * serviceCount) + 1;
  return serviceNameFromNumber(serviceNumber);
}

export function requestParams(serviceName) {
  return {
    headers: {
      Host: `${serviceName}.localhost`,
    },
    timeout: __ENV.E2E_REQUEST_TIMEOUT || '45s',
  };
}