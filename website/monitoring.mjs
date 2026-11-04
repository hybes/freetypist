export const defaultDsn = 'https://cdd8a725c00b40dd8ded87246c3c35b1@error.cnnct.uk/45';

const sensitiveKey = /authorization|cookie|password|secret|token|api[_-]?key|ip[_-]?address/i;

function scrubText(value) {
  return value
    .replace(/https?:\/\/[^\s<>"']+/gi, value => {
      try {
        const url = new URL(value);
        return `${url.origin}${url.pathname}`;
      } catch { return '[REDACTED URL]'; }
    })
    .replace(/([?&](?:[^=\s&]+)=)[^\s&#]*/g, '$1[REDACTED]')
    .replace(/\b((?:proxy[-_])?authorization|(?:set[-_])?cookie)\s*[:=]\s*[^\r\n]+/gi, '$1=[REDACTED]')
    .replace(/\b(Bearer\s+)[\w.~+/=-]+/gi, '$1[REDACTED]')
    .replace(/\b(authorization|cookie|password|secret|token|api[_-]?key)\s*[:=]\s*[^\s,;]+/gi, '$1=[REDACTED]')
    .replace(/\b[\w.+-]+@[\w.-]+\.[a-z]{2,}\b/gi, '[REDACTED EMAIL]');
}

function scrub(value, depth = 0) {
  if (depth > 10) return '[TRUNCATED]';
  if (typeof value === 'string') return scrubText(value);
  if (Array.isArray(value)) return value.map(entry => scrub(entry, depth + 1));
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value).map(([key, entry]) => [
    key, sensitiveKey.test(key) ? '[REDACTED]' : scrub(entry, depth + 1),
  ]));
}

export function sanitizeEvent(event) {
  try {
    const safe = scrub(event);
    delete safe.user;
    if (safe.request) {
      delete safe.request.headers;
      delete safe.request.cookies;
      delete safe.request.data;
      delete safe.request.query_string;
    }
    return safe;
  } catch { return null; }
}

export function monitoringOptions(env = {}, runtime = 'worker') {
  const environment = env.SENTRY_ENVIRONMENT || process.env.SENTRY_ENVIRONMENT || 'production';
  const explicitDsn = env.SENTRY_DSN?.trim();
  const testing = environment === 'test' || env.NODE_ENV === 'test' || process.env.NODE_ENV === 'test';
  return {
    dsn: explicitDsn || defaultDsn,
    enabled: !testing && (environment === 'production' || Boolean(explicitDsn)),
    environment,
    release: env.SENTRY_RELEASE || process.env.SENTRY_RELEASE || undefined,
    sampleRate: 1,
    tracesSampleRate: environment === 'production' ? 0.01 : 0,
    traceLifecycle: 'static',
    tracePropagationTargets: [],
    sendDefaultPii: false,
    dataCollection: {
      userInfo: false, cookies: false, httpHeaders: false, httpBodies: [], urlQueryParams: false,
      graphQL: { document: false, variables: false }, genAI: { inputs: false, outputs: false },
      mcp: { inputs: false, outputs: false }, databaseQueryData: false, queues: false,
      stackFrameVariables: false, frameContextLines: 0,
    },
    sendClientReports: false,
    beforeSendLog: () => null,
    beforeSendMetric: () => null,
    maxBreadcrumbs: 50,
    initialScope: { tags: { application: 'freetypist-website', monitoring_backend: 'glitchtip', runtime } },
    integrations: defaults => defaults.filter(integration => ![
      'BrowserSession', 'ProcessSession', 'CronTriggers', 'ConversationId',
    ].includes(integration.name)),
    beforeSend: sanitizeEvent,
    beforeSendTransaction: sanitizeEvent,
    beforeBreadcrumb: sanitizeEvent,
  };
}

export function sanitizeSpan(span) {
  return sanitizeEvent(span) || { ...span, description: '[REDACTED]', data: {} };
}
