import { build } from 'esbuild';
import { SentryCli } from '@sentry/cli';
import { cp, mkdir, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { scrubText } from './monitoring.mjs';

process.chdir(fileURLToPath(new URL('.', import.meta.url)));
const environment = process.env.SENTRY_ENVIRONMENT || 'production';
let commit = 'local';
try { commit = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch {}
const release = process.env.SENTRY_RELEASE || `freetypist-website@${commit}`;
const define = {
  'process.env.NODE_ENV': JSON.stringify(environment === 'test' ? 'test' : 'production'),
  'process.env.SENTRY_ENVIRONMENT': JSON.stringify(environment),
  'process.env.SENTRY_RELEASE': JSON.stringify(release),
  'process.env.PUBLIC_SENTRY_DSN': JSON.stringify(process.env.PUBLIC_SENTRY_DSN?.trim() || ''),
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
