import assert from 'node:assert/strict';
import { captureException, consoleLoggingIntegration, logger, withSentry, withStaticSpan } from '@sentry/cloudflare';
import { monitoringOptions, sanitizeSpan } from './monitoring.mjs';

// Sends one warn log, one error log and one error event through the Worker SDK config. All three start
// with `glitchtip-check:` and can be ignored or resolved in GlitchTip afterwards.
const sent = [];
const worker = withSentry(() => ({
  ...monitoringOptions({ SENTRY_DSN: process.env.SENTRY_DSN, SENTRY_ENVIRONMENT: 'production' }, 'worker', { consoleLoggingIntegration }),
  tracesSampleRate: 0,
  beforeSendSpan: withStaticSpan(sanitizeSpan),
  transportOptions: { fetch: async (url, options) => {
    const response = await fetch(url, options);
    const types = String(options.body).split('\n').map(line => { try { return JSON.parse(line).type; } catch { return undefined; } }).filter(Boolean);
    sent.push({ status: response.status, types });
    return response;
  } },
}), { fetch() {
  logger.warn('glitchtip-check: warn log from the Worker SDK (can be ignored)', { check: 'glitchtip-logs', 'http.response.status_code': 503 });
  logger.error('glitchtip-check: error log from the Worker SDK (can be ignored)', { check: 'glitchtip-logs', 'error.message': 'example failure' });
  captureException(new Error('glitchtip-check: test error event from the Worker SDK (can be resolved)'), { tags: { test: 'glitchtip-logs' } });
  return new Response('Test captured');
} });

const pending = [];
const response = await worker.fetch(new Request('https://type.cnnct.uk/glitchtip-check'), {}, { waitUntil: promise => pending.push(promise) });
await response.text();
await Promise.all(pending);
for (const { status, types } of sent) console.log(`GlitchTip envelope (${types.join(', ')}): HTTP ${status}`);
assert.ok(sent.length > 0 && sent.every(({ status }) => status === 200), 'GlitchTip must accept every envelope with HTTP 200');
assert.ok(sent.some(({ types }) => types.includes('event')), 'the error event must be sent');
assert.ok(sent.some(({ types }) => types.includes('log')), 'the logs must be sent');
console.log('GlitchTip accepted the glitchtip-check logs and error event.');
