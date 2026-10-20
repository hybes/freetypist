import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { readRelease } from './publish_release.mjs';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'freetypist-publisher-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const bytes = Buffer.from('isolated release fixture');
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const assets = ['dmg', 'zip'].map(extension => ({ file: `FreeTypist-1.1.0-arm64.${extension}`, size: bytes.length, sha256 }));
  const release = { version: '1.1.0', build: 2, notarised: true, minimumSystemVersion: '14.0', assets, ...assets[0] };
  for (const asset of assets) await writeFile(join(directory, asset.file), bytes);
  const save = () => writeFile(join(directory, 'mac.json'), JSON.stringify(release));
  await save();
  await writeFile(join(directory, 'appcast.xml'), '<rss><sparkle:version>2</sparkle:version><enclosure url="https://type.cnnct.uk/releases/FreeTypist-1.1.0-arm64.zip" sparkle:edSignature="fixture"/></rss>');
  return { directory, release, save };
}

test('publisher accepts matching files, build metadata and signed feed', async t => {
  const fixtureData = await fixture(t);
  assert.deepEqual(await readRelease(fixtureData.directory), fixtureData.release);
});
test('publisher rejects altered files before activating the release', async t => {
  const { directory, release } = await fixture(t);
  await writeFile(join(directory, release.assets[1].file), 'wrong content');
  await assert.rejects(readRelease(directory), /Checksum mismatch/);
});
test('publisher rejects unsigned builds, foreign paths and mismatched installer metadata', async t => {
  const { directory, release, save } = await fixture(t);
  release.notarised = false; await save();
  await assert.rejects(readRelease(directory), /unnotarised/);
  release.notarised = true; release.assets[0].file = '../../private'; await save();
  await assert.rejects(readRelease(directory), /Missing release assets/);
  release.assets[0].file = release.file; release.sha256 = '0'.repeat(64); await save();
  await assert.rejects(readRelease(directory), /Installer metadata/);
});
test('publisher rejects missing signatures and feeds for other releases', async t => {
  const { directory } = await fixture(t);
  await writeFile(join(directory, 'appcast.xml'), '<rss/>');
  await assert.rejects(readRelease(directory), /signed appcast/);
});
