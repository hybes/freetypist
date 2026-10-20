import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { handleRequest } from './worker.mjs';
const releaseOrigin = 'https://store.brth.uk/connect-dorset/freetypist/releases';

const release = { version: '1.1.0', file: 'FreeTypist-1.1.0-arm64.dmg', size: 12345, sha256: 'a'.repeat(64), notarised: true, minimumSystemVersion: '14.0' };
const request = (path, options) => new Request(`https://type.cnnct.uk${path}`, options);
const assets = { ASSETS: { fetch: async () => new Response('<h1>FreeTypist</h1>', { headers: { 'Content-Type': 'text/html' } }) } };

test('download uses the published, notarised release and bypasses stale caches', async () => {
  const upstream = async (url, options) => {
    assert.equal(url, `${releaseOrigin}/mac.json`);
    assert.equal(options.cache, 'no-store');
    return Response.json(release);
  };
  const response = await handleRequest(request('/download'), assets, upstream);
  assert.equal(response.status, 302);
  assert.equal(response.headers.get('Location'), '/releases/FreeTypist-1.1.0-arm64.dmg');
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  const head = await handleRequest(request('/release.json', { method: 'HEAD' }), assets, upstream);
  assert.equal(await head.text(), '');
});

test('missing, invalid or unnotarised releases do not advertise a download', async () => {
  for (const candidate of [{ ...release, notarised: false }, { ...release, file: 'https://elsewhere.invalid/app.dmg' }, { ...release, version: '9.0.0' }, { ...release, size: 0 }]) {
    assert.equal((await handleRequest(request('/download'), assets, async () => Response.json(candidate))).status, 503);
  }
  assert.equal((await handleRequest(request('/release.json'), assets, async () => new Response('', { status: 404 }))).status, 503);
  assert.equal((await handleRequest(request('/appcast.xml'), assets, async () => { throw new Error('offline'); })).status, 502);
});

test('range downloads keep their bytes, status, length and range headers', async () => {
  const upstream = async (url, options) => {
    assert.equal(url, `${releaseOrigin}/FreeTypist-1.1.0-arm64.zip`);
    assert.equal(options.headers.get('Range'), 'bytes=0-3');
    assert.equal(options.headers.get('Accept-Encoding'), 'identity');
    return new Response(new Uint8Array([1, 2, 3, 4]), { status: 206, headers: { 'Content-Length': '4', 'Content-Range': 'bytes 0-3/100' } });
  };
  const response = await handleRequest(request('/releases/FreeTypist-1.1.0-arm64.zip', { headers: { Range: 'bytes=0-3' } }), assets, upstream);
  assert.equal(response.status, 206);
  assert.equal(response.headers.get('Content-Length'), '4');
  assert.equal(response.headers.get('Content-Range'), 'bytes 0-3/100');
  assert.match(response.headers.get('Cache-Control'), /no-transform/);
  assert.deepEqual([...new Uint8Array(await response.arrayBuffer())], [1, 2, 3, 4]);
});

test('appcast is served without caching or transformation', async () => {
  const response = await handleRequest(request('/appcast.xml'), assets, async () => new Response('<rss/>'));
  assert.equal(await response.text(), '<rss/>');
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.match(response.headers.get('Content-Type'), /application\/xml/);
});

test('only public release files are proxied and writes are rejected', async () => {
  const unexpected = () => { throw new Error('Unexpected upstream call'); };
  for (const path of ['/releases/private.key', '/releases/mac.json', '/releases/staging/app.zip', '/releases/appcast.xml.bak']) {
    assert.equal((await handleRequest(request(path), assets, unexpected)).status, 404);
  }
  assert.equal((await worker.fetch(request('/download', { method: 'POST' }), assets, {})).status, 405);
});

test('Cloudflare execution context is not mistaken for the upstream fetch function', async () => {
  const response = await worker.fetch(request('/'), assets, { waitUntil() {} });
  assert.equal(response.status, 200);
  assert.match(await response.text(), /FreeTypist/);
  assert.match(response.headers.get('Content-Security-Policy'), /frame-ancestors 'none'/);
});
