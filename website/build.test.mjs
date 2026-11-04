import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { SentryCli } from '@sentry/cli';

test('builds skip missing tokens, upload when configured and tolerate upload failures without publishing maps', async () => {
  const cwd = fileURLToPath(new URL('.', import.meta.url));
  const temporary = await mkdtemp(join(cwd, '.wrangler-build-test-'));
  const executable = join(temporary, 'sentry-cli.cjs');
  const record = join(temporary, 'calls.jsonl');
  await writeFile(executable, `#!/usr/bin/env node
    const fs = require('node:fs');
    const assert = require('node:assert/strict');
    assert.equal(process.env.SENTRY_URL, 'https://error.cnnct.uk/');
    assert.equal(process.env.SENTRY_ORG, 'connect-dorset');
    assert.equal(process.env.SENTRY_PROJECT, 'freetypist-website');
    assert.ok(fs.existsSync('dist/public/app.js.map'));
    assert.ok(fs.existsSync('dist/worker.mjs.map'));
    fs.appendFileSync(process.env.TEST_CLI_RECORD, JSON.stringify(process.argv.slice(2)) + '\\n');
    if (process.argv.includes('inject')) {
      require('node:child_process').execFileSync(process.env.TEST_REAL_SENTRY_CLI, process.argv.slice(2), { stdio: 'ignore' });
      for (const file of ['dist/worker.mjs', 'dist/public/app.js']) {
        const map = JSON.parse(fs.readFileSync(file + '.map', 'utf8'));
        assert.ok(map.debugId);
        assert.ok(fs.readFileSync(file, 'utf8').includes(map.debugId));
      }
    }
    if (process.env.TEST_UPLOAD_FAIL === '1' && process.argv.includes('upload')) process.exit(1);
  `, { mode: 0o700 });
  try {
    for (const mode of ['missing', 'success', 'failure']) {
      await rm(record, { force: true });
      const output = execFileSync(process.execPath, ['build.mjs'], {
        cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
        env: {
          ...process.env, SENTRY_ENVIRONMENT: 'production', SENTRY_AUTH_TOKEN: mode === 'missing' ? '' : 'test-build-secret',
          SENTRY_BINARY_PATH: executable, TEST_CLI_RECORD: record, TEST_UPLOAD_FAIL: mode === 'failure' ? '1' : '0',
          TEST_REAL_SENTRY_CLI: SentryCli.getPath(),
        },
      });
      const publicFiles = await readdir(join(cwd, 'dist/public'));
      assert.ok(publicFiles.includes('app.js') && publicFiles.includes('index.html'));
      assert.ok(!publicFiles.some(file => file.endsWith('.map')));
      assert.ok(!(await readdir(join(cwd, 'dist'))).some(file => file.endsWith('.map')));
      assert.doesNotMatch(await readFile(join(cwd, 'dist/public/app.js'), 'utf8'), /test-build-secret|sourceMappingURL/);
      assert.doesNotMatch(await readFile(join(cwd, 'dist/worker.mjs'), 'utf8'), /test-build-secret|sourceMappingURL/);
      if (mode === 'missing') {
        assert.match(output, /upload skipped/);
        await assert.rejects(readFile(record), { code: 'ENOENT' });
      } else {
        const calls = (await readFile(record, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
        assert.deepEqual(calls.map(call => call.slice(0, 2)), [['sourcemaps', 'inject'], ['sourcemaps', 'upload']]);
        assert.ok(calls[1].includes('--release'));
        if (mode === 'success') assert.match(output, /source maps uploaded/);
      }
    }
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});
