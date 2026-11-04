import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { consoleLoggingIntegration, getDefaultIntegrations, withSentry } from '@sentry/cloudflare';
import { getDefaultIntegrations as browserIntegrations } from '@sentry/browser';
import {
  createLogger, createRepeatGate, defaultDsn, isSecretKey, monitoringOptions, sanitizeBreadcrumb, sanitizeEvent,
  sanitizeLog, sanitizeSpan, scrubText, scrubValue,
} from './monitoring.mjs';
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

test('GlitchTip options keep errors, logs, static traces and supported integrations', () => {
  const options = monitoringOptions({}, 'worker', { consoleLoggingIntegration });
  assert.equal(options.dsn, defaultDsn);
  assert.equal(options.sampleRate, 1);
  assert.equal(options.tracesSampleRate, 0.01);
  assert.equal(options.traceLifecycle, 'static');
  assert.equal(options.sendClientReports, false);
  assert.equal(options.beforeSendMetric({}), null);
  assert.deepEqual(options.initialScope.tags, { application: 'freetypist-website', service: 'freetypist-website', monitoring_backend: 'glitchtip', runtime: 'worker' });
  for (const integrations of [getDefaultIntegrations(options), browserIntegrations()]) {
    const names = options.integrations(integrations).map(integration => integration.name);
    assert.ok(!names.some(name => /Session|CronTriggers|ConversationId/.test(name)));
    assert.ok(names.includes('ConsoleLogs'));
  }
});

test('logs carry the service, runtime and host, and drop only duplicates and runtime noise', () => {
  const log = sanitizeLog({ level: 'warn', message: 'release: upstream returned 503', attributes: { 'service.name': 'other', 'user.email': 'ben@example.com' } }, { runtime: 'worker', hostName: 'web-1' });
  assert.equal(log.message, 'release: upstream returned 503');
  assert.deepEqual(log.attributes, { 'service.name': 'freetypist-website', runtime: 'worker', 'host.name': 'web-1', 'user.email': 'ben@example.com' });
  assert.equal(sanitizeLog({ level: 'error', message: 'x', attributes: {} }, { runtime: 'browser' }).attributes['host.name'], undefined);
  const consoleLog = message => ({ level: 'warn', message, attributes: { 'sentry.origin': 'auto.log.console' } });
  assert.equal(sanitizeLog(consoleLog('[freetypist-website] release: failed {}')), null);
  assert.equal(sanitizeLog(consoleLog('(node:1) ExperimentalWarning: VM modules are experimental')), null);
  assert.equal(sanitizeLog(consoleLog('(node:1) [MODULE_TYPELESS_PACKAGE_JSON] Warning: x')), null);
  assert.equal(sanitizeLog(consoleLog('third-party: widget failed password=hunter2')).message, 'third-party: widget failed password=[REDACTED]');
  const scrubbed = sanitizeLog({ level: 'error', message: 'email: send failed to ben@example.com, Bearer abc.def', attributes: { 'request.data.otp': '482913', apiKey: 'k', url: 'https://x.test/?token=t&page=2' } });
  assert.equal(scrubbed.message, 'email: send failed to ben@example.com, Bearer [REDACTED]');
  assert.equal(scrubbed.attributes['request.data.otp'], '[REDACTED]');
  assert.equal(scrubbed.attributes.apiKey, '[REDACTED]');
  assert.equal(scrubbed.attributes.url, 'https://x.test/?token=[REDACTED]&page=2');
});

test('the logger writes a prefixed, scrubbed console copy and an unprefixed GlitchTip line', () => {
  const sent = [];
  const printed = [];
  const sentry = { warn: (...args) => sent.push(args), error() {}, info() {} };
  const output = { warn: (...args) => printed.push(args), error() {}, info() {} };
  createLogger(sentry, { output }).warn('plunk: send failed 401 INVALID_KEY token=abc', { status: 401, password: 'hunter2' });
  assert.deepEqual(sent, [['plunk: send failed 401 INVALID_KEY token=abc', { status: 401, password: 'hunter2' }]]);
  assert.deepEqual(printed, [['[freetypist-website] plunk: send failed 401 INVALID_KEY token=[REDACTED]', { status: 401, password: '[REDACTED]' }]]);
  assert.doesNotThrow(() => createLogger({ warn() { throw new Error('offline'); } }, { output: null }).warn('x'));
});

test('repeat suppression holds back identical lines only within the window', () => {
  let time = 0;
  const gate = createRepeatGate(60_000, () => time);
  assert.deepEqual(gate('a'), { repeats: 0 });
  assert.equal(gate('a'), null);
  assert.equal(gate('a'), null);
  assert.deepEqual(gate('b'), { repeats: 0 });
  time = 60_000;
  assert.deepEqual(gate('a'), { repeats: 2 });
});

test('secret keys match in any form and at any depth', () => {
  for (const key of ['api-key', 'X-API-Key', 'apiKey', 'api_key', 'request.data.otp', 'password', 'mfa_code', 'recovery_codes',
    'totp', 'signupCode', 'invite_code', 'x-vercel-protection-bypass', 'x-vercel-set-bypass-cookie', '_vercel_jwt', 'Set-Cookie',
    'Proxy-Authorization', 'sessionId', 'session', 'client_secret', 'access_token', 'card_number', 'cvv', '%74oken']) {
    assert.ok(isSecretKey(key), key);
  }
  for (const key of ['email', 'name', 'phone', 'url', 'status', 'code', 'state', 'footprint', 'author', 'error.code', 'user.id']) {
    assert.ok(!isSecretKey(key), key);
  }
  assert.ok(isSecretKey('code', true) && isSecretKey('state', true) && isSecretKey('sig', true));
});

test('free text keeps context and redacts secret values only', () => {
  const cases = [
    ['Error: password=hunter2', 'Error: password=[REDACTED]'],
    ['Failure: access_token=abc', 'Failure: access_token=[REDACTED]'],
    ['error: otp=482913', 'error: otp=[REDACTED]'],
    ['session: could not verify the request for ben@example.com', 'session: could not verify the request for ben@example.com'],
    ['password: hunter2', 'password: [REDACTED]'],
    ['contact form sent to enquiries@example.com (subject "Quote", 412 ms)', 'contact form sent to enquiries@example.com (subject "Quote", 412 ms)'],
    ['fetch https://user:pw@x.test/cb?code=abc&state=xyz&page=2#access_token=t failed', 'fetch https://user:[REDACTED]@x.test/cb?code=[REDACTED]&state=[REDACTED]&page=2#access_token=[REDACTED] failed'],
    ['see /reset?%74oken=abc&email=a@b.co', 'see /reset?%74oken=[REDACTED]&email=a@b.co'],
    ['https://x.test/a?x-vercel-protection-bypass=s3cret', 'https://x.test/a?x-vercel-protection-bypass=[REDACTED]'],
    ['https://bucket.test/f?X-Amz-Signature=abc&X-Amz-Credential=k&X-Amz-Expires=60', 'https://bucket.test/f?X-Amz-Signature=[REDACTED]&X-Amz-Credential=[REDACTED]&X-Amz-Expires=60'],
    ['cookie=a="secret value"; theme=dark', 'cookie=[REDACTED]'],
    ['request failed\nAuthorization: Basic dXNlcjpwYXNz\nCookie: _vercel_jwt="x"; a=b\nSet-Cookie: sid=1; Path=/', 'request failed\nAuthorization: [REDACTED]\nCookie: [REDACTED]\nSet-Cookie: [REDACTED]'],
    ['headers sent proxy-authorization: bearer abc def', 'headers sent proxy-authorization: [REDACTED]'],
    ['upstream said BEARER abc.def-123 was rejected', 'upstream said BEARER [REDACTED] was rejected'],
    ['note: basic configuration missing', 'note: basic configuration missing'],
    ['authorization=Bearer abc, retrying', 'authorization=[REDACTED], retrying'],
    ['{"password":"x=1","note":"call me"}', '{"password":"[REDACTED]","note":"call me"}'],
    ['secret=["a","b"] codes={"backup":["1","2"]} left', 'secret=[REDACTED] codes={"backup":["1","2"]} left'],
    ['recovery_codes=[1, 2, 3] next', 'recovery_codes=[REDACTED] next'],
    ['lookup failed, parameters: ["ben@example.com", "password=hunter2"]', 'lookup failed, parameters: ["ben@example.com", "password=[REDACTED]"]'],
    ['query failed: INSERT INTO users (email, password) VALUES ($1, $2); parameters: ["ben@example.com", "hunter2"]', 'query failed: INSERT INTO users (email, password) VALUES ($1, $2); parameters: [REDACTED]'],
    ['query failed: SELECT * FROM orders WHERE email = $1; parameters: ["ben@example.com"]', 'query failed: SELECT * FROM orders WHERE email = $1; parameters: ["ben@example.com"]'],
    ['password: ["hunter2", "secret2"]', 'password: [REDACTED]'],
    ['password: "hunter2 secret"', 'password: "[REDACTED]"'],
    ['token: abc123 expired', 'token: [REDACTED] expired'],
    ['Cookie=a="secret"; b="othersecret"', 'Cookie=[REDACTED]'],
    ['card 4242 4242 4242 4242 declined, order 1762214400000', 'card [REDACTED CARD] declined, order 1762214400000'],
    ['invite_code=XY12 signup-code: QQ9', 'invite_code=[REDACTED] signup-code: [REDACTED]'],
  ];
  for (const [input, expected] of cases) assert.equal(scrubText(input), expected, input);
  assert.equal(scrubText('token=abc&page=2&code=x', { query: true }), 'token=[REDACTED]&page=2&code=[REDACTED]');
});

test('objects keep personal data and redact whole secret values at any depth', () => {
  const event = {
    user: { id: '42', email: 'ben@example.com', username: 'Ben' },
    request: {
      url: 'https://type.cnnct.uk/download?token=private&ref=newsletter',
      query_string: [['code', 'private'], ['ref', 'newsletter']],
      headers: { Authorization: 'Bearer private', 'X-API-Key': 'private', cookie: 'a=private', 'User-Agent': 'Safari', Referer: 'https://example.com/?a=1' },
      cookies: { _vercel_jwt: 'private', theme: 'dark' },
      data: '{"name":"Ben","email":"ben@example.com","message":"a=b&c=d password=private","otp":"private","card":"4242424242424242"}',
    },
    exception: { values: [{ type: 'Error', value: 'Failed https://type.cnnct.uk/?email=ben@example.com&access_token=private' }] },
    extra: { nested: { deeper: { apiKey: ['private', 'private'], secret: { a: 'private' }, phone: '+44 7700 900123' } } },
    breadcrumbs: [{ category: 'console', message: 'error: otp=private', data: { arguments: ['token=private', { password: 'private' }], url: 'https://x.test/?sig=private' } }],
  };
  const safe = sanitizeEvent(event);
  const text = JSON.stringify(safe);
  assert.doesNotMatch(text, /private/);
  assert.deepEqual(safe.user, event.user);
  assert.equal(safe.request.url, 'https://type.cnnct.uk/download?token=[REDACTED]&ref=newsletter');
  assert.deepEqual(safe.request.query_string, [['code', '[REDACTED]'], ['ref', 'newsletter']]);
  assert.equal(safe.request.headers['User-Agent'], 'Safari');
  assert.equal(safe.request.headers.Referer, 'https://example.com/?a=1');
  assert.equal(safe.request.cookies, '[REDACTED]');
  assert.deepEqual(JSON.parse(safe.request.data), { name: 'Ben', email: 'ben@example.com', message: 'a=b&c=d password=[REDACTED]', otp: '[REDACTED]', card: '[REDACTED CARD]' });
  assert.match(safe.exception.values[0].value, /email=ben@example\.com&access_token=\[REDACTED\]/);
  assert.equal(safe.extra.nested.deeper.apiKey, '[REDACTED]');
  assert.equal(safe.extra.nested.deeper.secret, '[REDACTED]');
  assert.equal(safe.extra.nested.deeper.phone, '+44 7700 900123');
  assert.ok(event.request.headers.Authorization === 'Bearer private', 'the original event is not mutated');
  const json = { otp: '1', note: 'x' };
  assert.deepEqual(JSON.parse(scrubValue(JSON.stringify(json), 'data')), scrubValue(json, 'data'));
  assert.deepEqual(scrubValue({ query: { token: 'private', page: '2', key: 'private' } }), { query: { token: '[REDACTED]', page: '2', key: '[REDACTED]' } });
  assert.deepEqual(sanitizeBreadcrumb({ data: { arguments: ['Error: password=hunter2'] } }), { data: { arguments: ['Error: password=[REDACTED]'] } });
  const span = sanitizeSpan({ description: 'GET https://x.test/a?token=private', data: { 'url.query': 'token=private&state=private&page=1', 'http.request.header.cookie': 'private', 'url.full': 'https://x.test/a?signature=private' } });
  assert.doesNotMatch(JSON.stringify(span), /private/);
  assert.equal(span.data['url.query'], 'token=[REDACTED]&state=[REDACTED]&page=1');
  assert.equal(sanitizeEvent({ request: { data: { card: 4242424242424242, amount: 1999, at: 1762214400000 } } }).request.data.card, '[REDACTED CARD]');
  assert.equal(sanitizeEvent({ request: { data: { amount: 1999, at: 1762214400000 } } }).request.data.at, 1762214400000);
  assert.deepEqual(JSON.parse(scrubValue('{"card":4242424242424242}', 'data')), { card: '[REDACTED CARD]' });
  assert.deepEqual(sanitizeEvent({ request: { data: { code: 'oauth-abc', state: 'csrf-xyz', next: '/account' } } }).request.data, { code: '[REDACTED]', state: '[REDACTED]', next: '/account' });
  assert.equal(scrubValue('code=oauth-abc&state=csrf-xyz&next=%2F', 'data'), 'code=[REDACTED]&state=[REDACTED]&next=%2F');
  assert.deepEqual(scrubValue({ error: { code: 'INVALID_KEY', status: 401 } }), { error: { code: 'INVALID_KEY', status: 401 } });
  assert.deepEqual(scrubValue({ sql: 'INSERT INTO users (email, password) VALUES ($1, $2)', parameters: ['ben@example.com', 'hunter2'] }).parameters, '[REDACTED]');
  assert.deepEqual(scrubValue({ sql: 'SELECT * FROM orders WHERE email = $1', parameters: ['ben@example.com'] }).parameters, ['ben@example.com']);
  const circular = { name: 'a' };
  circular.self = circular;
  assert.equal(scrubValue(circular).self, '[Circular]');
  const shared = { email: 'a@b.co' };
  assert.deepEqual(scrubValue({ a: shared, b: shared }), { a: shared, b: shared });
  const broken = sanitizeEvent({ event_id: '1', get user() { throw new Error('password=hunter2'); } });
  assert.equal(broken.event_id, '1');
  assert.equal(broken.message, 'monitoring: event could not be scrubbed (Error)');
  const brokenLog = sanitizeLog({ level: 'warn', message: 'x', attributes: { context: { get note() { throw new Error('password=hunter2'); } } } }, { runtime: 'worker' });
  assert.equal(brokenLog.message, 'monitoring: log could not be scrubbed (Error)');
});

test('the scrubber is linear and caps very long values', () => {
  for (const input of ['a'.repeat(100_000), 'a.'.repeat(50_000), 'password='.repeat(11_000), '"'.repeat(100_000), 'k=v&'.repeat(25_000), '1 '.repeat(50_000)]) {
    const started = performance.now();
    const output = scrubText(input);
    assert.ok(performance.now() - started < 100, `took too long for ${input.slice(0, 10)}`);
    assert.match(output, /…\[truncated \d+ chars\]$/);
  }
});

test('the Worker SDK sends handled errors, unexpected errors and structured logs', async () => {
  const envelopes = [];
  const pending = [];
  const options = {
    ...monitoringOptions({}, 'worker', { consoleLoggingIntegration }), enabled: true, cacheClient: false, tracesSampleRate: 0,
    transport: () => ({
      send: async envelope => { envelopes.push(envelope); return { statusCode: 200 }; },
      flush: async () => true,
    }),
  };
  const release = { version: '1.1.0', file: 'FreeTypist-1.1.0-arm64.dmg', size: 12345, sha256: 'a'.repeat(64), notarised: true, minimumSystemVersion: '14.0' };
  const worker = withSentry(() => options, { async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path === '/unexpected') throw new Error('Unexpected asset failure');
    if (path === '/release.json') return handleRequest(request, env, async () => new Response('down', { status: 503 }));
    if (path === '/download') return handleRequest(request, env, async () => Response.json(release));
    if (path === '/console') { console.warn('(node:1) ExperimentalWarning: noisy'); console.error('third-party: failed token=abc'); return new Response('ok'); }
    return handleRequest(request, env, async () => { throw new Error('Release store offline'); });
  } });
  const ctx = { waitUntil: promise => pending.push(promise) };
  const status = async path => {
    const response = await worker.fetch(new Request(`https://type.cnnct.uk${path}`), {}, ctx);
    await response.text();
    return response.status;
  };
  assert.equal(await status('/appcast.xml'), 502);
  assert.equal(await status('/release.json'), 503);
  assert.equal(await status('/download'), 302);
  assert.equal(await status('/console'), 200);
  await assert.rejects(worker.fetch(new Request('https://type.cnnct.uk/unexpected'), {}, ctx), /Unexpected asset failure/);
  await Promise.all(pending);
  const items = envelopes.flatMap(([, entries]) => entries);
  const errors = items.filter(([header]) => header.type === 'event').map(([, event]) => event);
  const logs = items.filter(([header]) => header.type === 'log').flatMap(([, payload]) => payload.items);
  assert.equal(errors.length, 3);
  assert.deepEqual(errors.map(event => event.tags.operation), ['release_download', 'release_metadata', undefined]);
  assert.ok(errors.every(event => event.tags.service === 'freetypist-website' && event.tags.application === 'freetypist-website'));
  const lines = logs.map(entry => `${entry.level} ${entry.body}`);
  assert.equal(lines.length, 4, lines.join('\n'));
  assert.match(lines[0], /^error release: appcast\.xml fetch failed, Error: Release store offline \(\d+ ms\)$/);
  assert.match(lines[1], /^error release: metadata upstream returned 503 for \/release\.json \(\d+ ms\)$/);
  assert.equal(lines[2], 'info download: redirected to FreeTypist-1.1.0-arm64.dmg (v1.1.0)');
  assert.equal(lines[3], 'error third-party: failed token=[REDACTED]');
  for (const entry of logs) {
    assert.deepEqual(entry.attributes['service.name'], { type: 'string', value: 'freetypist-website' });
    assert.deepEqual(entry.attributes.runtime, { type: 'string', value: 'worker' });
    assert.equal(entry.attributes['host.name'], undefined);
    assert.equal(entry.attributes['sentry.environment'].value, 'production');
  }
  assert.equal(logs[1].attributes['http.response.status_code'].value, 503);
  assert.equal(logs[1].attributes['url.path'].value, '/release.json');
  assert.equal(logs[2].attributes['release.version'].value, '1.1.0');
});
