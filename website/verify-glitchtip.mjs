import assert from 'node:assert/strict';
import { captureException, withSentry, withStaticSpan } from '@sentry/cloudflare';
import { monitoringOptions, sanitizeSpan } from './monitoring.mjs';

const pending = [];
const statuses = [];
const worker = withSentry(() => ({
  ...monitoringOptions({ SENTRY_DSN: process.env.SENTRY_DSN, SENTRY_ENVIRONMENT: 'production' }),
  tracesSampleRate: 0,
  beforeSendSpan: withStaticSpan(sanitizeSpan),
  transportOptions: { fetch: async (url, options) => {
    const response = await fetch(url, options);
    statuses.push(response.status);
    return response;
  } },
}), { fetch() {
  captureException(new Error('FreeTypist website GlitchTip migration test'), { tags: { test: 'glitchtip-migration' } });
  return new Response('Test captured');
} });

const response = await worker.fetch(new Request('https://type.cnnct.uk/'), {}, { waitUntil: promise => pending.push(promise) });
await response.text();
await Promise.all(pending);
assert.deepEqual(statuses, [200], 'GlitchTip must accept exactly one error envelope with HTTP 200');
console.log('GlitchTip accepted the migration test error: HTTP 200. The test event can be resolved.');
