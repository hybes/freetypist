import { captureException, consoleLoggingIntegration, logger, withSentry, withStaticSpan } from '@sentry/cloudflare';
import { createLogger, createRepeatGate, defaultDsn, errorAttributes, monitoringOptions, sanitizeSpan } from './monitoring.mjs';

const releaseOrigin = 'https://store.brth.uk/connect-dorset/freetypist/releases';
const archiveName = /^FreeTypist-\d+\.\d+\.\d+-arm64\.(dmg|zip)(\.sha256)?$/;

const log = createLogger(logger);
const once = createRepeatGate();

// Returns the first reason the release metadata is unusable, or null when it is valid.
export function releaseProblem(release) {
  if (!release || typeof release !== 'object') return 'metadata is not an object';
  if (!/^\d+\.\d+\.\d+$/.test(release.version)) return `version ${JSON.stringify(release.version)} is not x.y.z`;
  if (release.file !== `FreeTypist-${release.version}-arm64.dmg`) return `file ${JSON.stringify(release.file)} does not match the version`;
  if (!Number.isSafeInteger(release.size) || release.size <= 0) return `size ${JSON.stringify(release.size)} is not a positive integer`;
  if (!/^[a-f0-9]{64}$/.test(release.sha256)) return 'sha256 is not a 64-character hex digest';
  if (release.notarised !== true) return 'notarised is not true';
  if (!/^\d+\.\d+(\.\d+)?$/.test(release.minimumSystemVersion)) return `minimumSystemVersion ${JSON.stringify(release.minimumSystemVersion)} is not valid`;
  return null;
}

export const validRelease = release => releaseProblem(release) === null;

function requestAttributes(request, url) {
  return {
    'http.request.method': request.method, 'url.path': url.pathname, 'url.full': url.href,
    'cloudflare.colo': request.cf?.colo, 'client.country': request.cf?.country,
  };
}

// Logs once per minute per key; the next line carries the number of repeats held back.
function logOnce(level, key, message, attributes) {
  const gate = once(key);
  if (!gate) return;
  log[level](gate.repeats ? `${message}, ${gate.repeats} repeats in the last minute` : message, { ...attributes, repeats: gate.repeats });
}

const unavailable = (message, status = 503) => new Response(message, {
  status, headers: { 'Cache-Control': 'no-store', 'Content-Type': 'text/plain; charset=utf-8' },
});

export async function handleRequest(request, env, upstream = fetch) {
  const url = new URL(request.url);
  if (!['GET', 'HEAD'].includes(request.method)) return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
  if (url.pathname === '/release.json' || url.pathname === '/download') {
    const started = Date.now();
    let stage = 'fetch';
    let status;
    let release;
    try {
      const response = await upstream(`${releaseOrigin}/mac.json`, { cache: 'no-store' });
      status = response.status;
      if (!response.ok) { stage = 'status'; throw new Error(`Release metadata returned HTTP ${status}`); }
      stage = 'parse';
      release = await response.json();
      stage = 'validate';
      const problem = releaseProblem(release);
      if (problem) throw new Error(`Invalid release metadata: ${problem}`);
      if (url.pathname === '/download') {
        log.info(`download: redirected to ${release.file} (v${release.version})`, {
          ...requestAttributes(request, url), 'release.version': release.version, 'release.file': release.file,
          'release.size': release.size, 'http.request.header.referer': request.headers.get('Referer') || undefined,
          'user_agent.original': request.headers.get('User-Agent') || undefined,
        });
        return new Response(null, { status: 302, headers: {
          Location: `/releases/${release.file}`, 'Cache-Control': 'no-store',
        } });
      }
      return new Response(request.method === 'HEAD' ? null : JSON.stringify(release), {
        headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
      });
    } catch (error) {
      const duration = Date.now() - started;
      const what = { fetch: `fetch failed, ${error?.name}: ${error?.message}`, status: `upstream returned ${status}`,
        parse: `is not valid JSON, ${error?.message}`, validate: `rejected, ${String(error?.message).replace(/^Invalid release metadata: /, '')}` }[stage];
      logOnce('error', `release.json:${stage}:${status}:${error?.message}`, `release: metadata ${what} for ${url.pathname} (${duration} ms)`, {
        ...requestAttributes(request, url), ...errorAttributes(error), stage, 'http.response.status_code': status,
        'duration_ms': duration, 'upstream.url': `${releaseOrigin}/mac.json`,
        'release.version': release?.version, 'release.file': release?.file,
      });
      captureException(error, { tags: { operation: 'release_metadata', stage } });
      return unavailable('The Mac download is being prepared. Please try again shortly.');
    }
  }
  if (url.pathname === '/appcast.xml' || url.pathname.startsWith('/releases/')) {
    const name = url.pathname === '/appcast.xml' ? 'appcast.xml' : url.pathname.slice('/releases/'.length);
    if (!archiveName.test(name) && name !== 'appcast.xml') return unavailable('Not found', 404);
    const headers = new Headers({ 'Accept-Encoding': 'identity' });
    for (const name of ['Range', 'If-Range', 'If-None-Match']) {
      if (request.headers.has(name)) headers.set(name, request.headers.get(name));
    }
    const started = Date.now();
    try {
      const response = await upstream(`${releaseOrigin}/${name}`, { method: request.method, headers, cache: 'no-store' });
      if (response.status >= 400 && response.status !== 416) {
        const level = response.status >= 500 || name === 'appcast.xml' ? 'error' : 'warn';
        const duration = Date.now() - started;
        logOnce(level, `release:${name}:${response.status}`, `release: upstream returned ${response.status} for ${name} (${duration} ms)`, {
          ...requestAttributes(request, url), 'release.file': name, 'http.response.status_code': response.status,
          'duration_ms': duration, 'upstream.url': `${releaseOrigin}/${name}`,
        });
      }
      const outgoing = new Headers(response.headers);
      outgoing.set('Cache-Control', name === 'appcast.xml' ? 'no-store' : 'public, max-age=86400, no-transform');
      outgoing.set('X-Content-Type-Options', 'nosniff');
      if (name === 'appcast.xml') outgoing.set('Content-Type', 'application/xml; charset=utf-8');
      return new Response(request.method === 'HEAD' ? null : response.body, { status: response.status, headers: outgoing });
    } catch (error) {
      const duration = Date.now() - started;
      logOnce('error', `release:${name}:fetch:${error?.message}`, `release: ${name} fetch failed, ${error?.name}: ${error?.message} (${duration} ms)`, {
        ...requestAttributes(request, url), ...errorAttributes(error), 'release.file': name,
        'duration_ms': duration, 'upstream.url': `${releaseOrigin}/${name}`,
      });
      captureException(error, { tags: { operation: 'release_download' } });
      return unavailable('Download unavailable. Please try again.', 502);
    }
  }
  const response = await env.ASSETS.fetch(request);
  const headers = new Headers(response.headers);
  const ingestOrigin = new URL(process.env.PUBLIC_SENTRY_DSN?.trim() || defaultDsn).origin;
  headers.set('Content-Security-Policy', `default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self' ${ingestOrigin}; object-src 'none'; base-uri 'none'; frame-ancestors 'none'`);
  headers.set('X-Content-Type-Options', 'nosniff');
  headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
  return new Response(request.method === 'HEAD' ? null : response.body, { status: response.status, headers });
}

export default withSentry(env => ({
  ...monitoringOptions(env, 'worker', { consoleLoggingIntegration }),
  beforeSendSpan: withStaticSpan(sanitizeSpan),
}), { fetch(request, env) { return handleRequest(request, env); } });
