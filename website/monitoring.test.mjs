import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { getDefaultIntegrations, withSentry } from '@sentry/cloudflare';
import { getDefaultIntegrations as browserIntegrations } from '@sentry/browser';
import { defaultDsn, monitoringOptions, sanitizeEvent, sanitizeSpan } from './monitoring.mjs';
import { handleRequest } from './worker.mjs';

test('tests cannot send events, including with an explicit DSN', () => {
  assert.equal(monitoringOptions().enabled, false);
  assert.equal(monitoringOptions({ SENTRY_DSN: defaultDsn }).enabled, false);
});

test('production uses the default DSN and development needs an explicit DSN', () => {
  const result = execFileSync(process.execPath, ['--input-type=module', '-e', `
    import { monitoringOptions } from './monitoring.mjs';
    console.log(JSON.stringify([
      monitoringOptions(),
      monitoringOptions({ SENTRY_ENVIRONMENT: 'development' }),
      monitoringOptions({ SENTRY_ENVIRONMENT: 'development', SENTRY_DSN: 'https://public@errors.example/1' }),
      monitoringOptions({ SENTRY_ENVIRONMENT: 'test', SENTRY_DSN: 'https://public@errors.example/1' }),
    ]));
  `], { cwd: new URL('.', import.meta.url), env: { ...process.env, NODE_ENV: 'production', SENTRY_ENVIRONMENT: '' }, encoding: 'utf8' });
  const [production, development, explicitDevelopment, testing] = JSON.parse(result);
  assert.equal(production.enabled, true);
  assert.equal(production.dsn, defaultDsn);
  assert.equal(development.enabled, false);
  assert.equal(development.tracesSampleRate, 0);
  assert.equal(explicitDevelopment.enabled, true);
  assert.equal(explicitDevelopment.dsn, 'https://public@errors.example/1');
  assert.equal(testing.enabled, false);
});

test('GlitchTip options keep errors, static traces and supported integrations', () => {
  const options = monitoringOptions();
  assert.equal(options.dsn, defaultDsn);
  assert.equal(options.sampleRate, 1);
  assert.equal(options.tracesSampleRate, 0.01);
  assert.equal(options.traceLifecycle, 'static');
  assert.equal(options.sendClientReports, false);
  assert.equal(options.beforeSendLog({}), null);
  assert.equal(options.beforeSendMetric({}), null);
  assert.equal(options.initialScope.tags.application, 'freetypist-website');
  for (const integrations of [getDefaultIntegrations(options), browserIntegrations()]) {
    assert.ok(!options.integrations(integrations).some(integration => /Session|CronTriggers|ConversationId/.test(integration.name)));
  }
});

test('errors, breadcrumbs and spans omit personal data and credentials', () => {
  const event = {
    user: { email: 'private@example.com', ip_address: '192.0.2.1' },
    request: {
      url: 'https://user:pass@type.cnnct.uk/download?token=private#private',
      headers: { authorization: 'Bearer private', cookie: 'session=private' },
      cookies: { session: 'private' }, data: 'private', query_string: 'email=private',
    },
    exception: { values: [{ value: 'Failed https://type.cnnct.uk/?email=private#private Bearer private password=private private@example.com' }] },
    extra: { nested: { apiKey: 'private', access_token: 'private' } },
    breadcrumbs: [{ data: { url: 'https://type.cnnct.uk/?token=private', authorization: 'private' } }],
  };
  const safe = sanitizeEvent(event);
  assert.equal(safe.request.url, 'https://type.cnnct.uk/download');
  assert.equal(safe.user, undefined);
  assert.deepEqual(Object.keys(safe.request), ['url']);
  assert.doesNotMatch(JSON.stringify(safe), /private|user:pass/);
  assert.ok(event.user, 'the original event is not mutated');
  assert.doesNotMatch(JSON.stringify(sanitizeSpan({ description: 'Bearer private', data: { 'http.request.header.cookie': 'private' } })), /private/);
  assert.doesNotMatch(JSON.stringify(sanitizeEvent({ message: 'Authorization: Basic private\nCookie: session=private; other=private' })), /private/);
  assert.equal(sanitizeEvent({ get user() { throw new Error('unsafe getter'); } }), null);
});

test('the Worker SDK captures handled upstream errors and unexpected handler errors', async () => {
  const envelopes = [];
  const pending = [];
  const options = {
    ...monitoringOptions(), enabled: true, cacheClient: false, tracesSampleRate: 0,
    transport: () => ({
      send: async envelope => { envelopes.push(envelope); return { statusCode: 200 }; },
      flush: async () => true,
    }),
  };
  const worker = withSentry(() => options, { async fetch(request, env) {
    if (new URL(request.url).pathname === '/unexpected') throw new Error('Unexpected asset failure');
    return handleRequest(request, env, async () => { throw new Error('Release store offline'); });
  } });
  const ctx = { waitUntil: promise => pending.push(promise) };
  assert.equal((await worker.fetch(new Request('https://type.cnnct.uk/download'), {}, ctx)).status, 503);
  await assert.rejects(worker.fetch(new Request('https://type.cnnct.uk/unexpected'), {}, ctx), /Unexpected asset failure/);
  await Promise.all(pending);
  const errors = envelopes.flatMap(([, items]) => items.filter(([header]) => header.type === 'event').map(([, event]) => event));
  assert.equal(errors.length, 2);
  assert.equal(errors[0].tags.operation, 'release_metadata');
  assert.match(errors[0].exception.values[0].value, /Release store offline/);
  assert.match(errors[1].exception.values[0].value, /Unexpected asset failure/);
  assert.ok(errors.every(event => event.tags.application === 'freetypist-website' && !event.user && !event.request?.headers));
});
