import { build } from 'esbuild';
import { SentryCli } from '@sentry/cli';
import { cp, mkdir, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { deployment, scrubText } from './monitoring.mjs';

process.chdir(fileURLToPath(new URL('.', import.meta.url)));

// Wrangler sets WRANGLER_COMMAND=deploy for `wrangler deploy --dry-run` too, and gives the build no other sign of
// it, so look for the flag on the Wrangler CLI process that started this build, and only that one: a shell or
// CI script above it may mention `--dry-run` for another command. If `ps` is unavailable this finds nothing and
// the build stays a deployment build.
function wranglerDryRun() {
  let pid = process.ppid;
  for (let depth = 0; depth < 8 && pid > 1; depth++) {
    let line;
    try { line = execFileSync('ps', ['-o', 'ppid=', '-o', 'args=', '-p', String(pid)], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { return false; }
    const [, parent, args = ''] = line.match(/^(\d+)\s*(.*)$/s) || [];
    if (/wrangler-dist[\\/]cli\.js(\s|$)/.test(args)) return /\s--dry-run(=true)?(\s|$)/.test(args);
    pid = Number(parent);
  }
  return false;
}
if (process.env.WRANGLER_COMMAND && wranglerDryRun()) {
  console.log('Dry run: this build will not report to GlitchTip.');
  process.env.WRANGLER_COMMAND = '';
}

// Production or preview only under `wrangler deploy` or `wrangler versions upload`; development otherwise.
const { environment } = deployment();
let commit = 'local';
try { commit = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch {}
const release = process.env.SENTRY_RELEASE || `freetypist-website@${commit}`;
const define = {
  'process.env.NODE_ENV': JSON.stringify(environment === 'test' ? 'test' : 'production'),
  'process.env.SENTRY_ENVIRONMENT': JSON.stringify(environment),
  'process.env.SENTRY_RELEASE': JSON.stringify(release),
  'process.env.PUBLIC_SENTRY_DSN': JSON.stringify(process.env.PUBLIC_SENTRY_DSN?.trim() || ''),
  'process.env.WRANGLER_COMMAND': JSON.stringify(process.env.WRANGLER_COMMAND?.trim() || ''),
  'process.env.SENTRY_FORCE': JSON.stringify(process.env.SENTRY_FORCE?.trim() || ''),
  __SENTRY_DEBUG__: 'false',
};

await rm('dist', { recursive: true, force: true });
await mkdir('dist', { recursive: true });
await cp('public', 'dist/public', { recursive: true, filter: path => !path.endsWith('.map') });
await build({
  entryPoints: ['worker.mjs'], outfile: 'dist/worker.mjs', bundle: true, format: 'esm',
  platform: 'neutral', mainFields: ['module', 'main'], conditions: ['workerd', 'production'],
  external: ['node:*', 'cloudflare:*'], target: 'es2022', sourcemap: 'external', define,
});
await build({
  entryPoints: ['public/app.js'], outfile: 'dist/public/app.js', bundle: true, format: 'iife',
  platform: 'browser', target: 'es2022', sourcemap: 'external', define,
});

try {
  if (process.env.SENTRY_AUTH_TOKEN?.trim() && environment === 'production') {
    const cli = new SentryCli(null, {
      url: 'https://error.cnnct.uk/', org: 'connect-dorset', project: 'freetypist-website',
      authToken: process.env.SENTRY_AUTH_TOKEN,
    });
    await cli.execute(['sourcemaps', 'inject', 'dist'], false);
    await cli.execute(['sourcemaps', 'upload', '--release', release, 'dist'], false);
    console.log('GlitchTip source maps uploaded.');
  } else {
    console.log('GlitchTip source-map upload skipped (no build token or not production).');
  }
} catch (error) {
  console.warn(`GlitchTip source-map upload failed; continuing the build. ${scrubText(error?.message || error)}`);
} finally {
  await rm('dist/public/app.js.map', { force: true });
  await rm('dist/worker.mjs.map', { force: true });
}
