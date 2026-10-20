const releaseOrigin = 'https://store.brth.uk/connect-dorset/freetypist/releases';
const archiveName = /^FreeTypist-\d+\.\d+\.\d+-arm64\.(dmg|zip)(\.sha256)?$/;

export function validRelease(release) {
  return release && /^\d+\.\d+\.\d+$/.test(release.version)
    && release.file === `FreeTypist-${release.version}-arm64.dmg`
    && Number.isSafeInteger(release.size) && release.size > 0
    && /^[a-f0-9]{64}$/.test(release.sha256) && release.notarised === true
    && /^\d+\.\d+(\.\d+)?$/.test(release.minimumSystemVersion);
}

const unavailable = (message, status = 503) => new Response(message, {
  status, headers: { 'Cache-Control': 'no-store', 'Content-Type': 'text/plain; charset=utf-8' },
});

export async function handleRequest(request, env, upstream = fetch) {
  const url = new URL(request.url);
  if (!['GET', 'HEAD'].includes(request.method)) return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
  if (url.pathname === '/release.json' || url.pathname === '/download') {
    try {
      const response = await upstream(`${releaseOrigin}/mac.json`, { cache: 'no-store' });
      if (!response.ok) throw new Error('Release unavailable');
      const release = await response.json();
      if (!validRelease(release)) throw new Error('Invalid release');
      if (url.pathname === '/download') return new Response(null, { status: 302, headers: {
        Location: `/releases/${release.file}`, 'Cache-Control': 'no-store',
      } });
      return new Response(request.method === 'HEAD' ? null : JSON.stringify(release), {
        headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
      });
    } catch { return unavailable('The Mac download is being prepared. Please try again shortly.'); }
  }
  if (url.pathname === '/appcast.xml' || url.pathname.startsWith('/releases/')) {
    const name = url.pathname === '/appcast.xml' ? 'appcast.xml' : url.pathname.slice('/releases/'.length);
    if (!archiveName.test(name) && name !== 'appcast.xml') return unavailable('Not found', 404);
    const headers = new Headers({ 'Accept-Encoding': 'identity' });
    for (const name of ['Range', 'If-Range', 'If-None-Match']) {
      if (request.headers.has(name)) headers.set(name, request.headers.get(name));
    }
    try {
      const response = await upstream(`${releaseOrigin}/${name}`, { method: request.method, headers, cache: 'no-store' });
      const outgoing = new Headers(response.headers);
      outgoing.set('Cache-Control', name === 'appcast.xml' ? 'no-store' : 'public, max-age=86400, no-transform');
      outgoing.set('X-Content-Type-Options', 'nosniff');
      if (name === 'appcast.xml') outgoing.set('Content-Type', 'application/xml; charset=utf-8');
      return new Response(request.method === 'HEAD' ? null : response.body, { status: response.status, headers: outgoing });
    } catch { return unavailable('Download unavailable. Please try again.', 502); }
  }
  const response = await env.ASSETS.fetch(request);
  const headers = new Headers(response.headers);
  headers.set('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'");
  headers.set('X-Content-Type-Options', 'nosniff');
  headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
  return new Response(request.method === 'HEAD' ? null : response.body, { status: response.status, headers });
}

export default { fetch(request, env) { return handleRequest(request, env); } };
