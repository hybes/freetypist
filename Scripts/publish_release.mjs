import { readFile, writeFile, stat } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { validRelease } from '../website/worker.mjs';

const origin = 'https://store.brth.uk/connect-dorset/freetypist/releases';
const destination = 'brth/connect-dorset/freetypist/releases';
const hash = async stream => {
  const digest = createHash('sha256');
  for await (const chunk of stream) digest.update(chunk);
  return digest.digest('hex');
};

export async function readRelease(directory) {
  const release = JSON.parse(await readFile(join(directory, 'mac.json')));
  if (!validRelease(release) || !Number.isSafeInteger(release.build) || release.build < 1) throw new Error('Invalid or unnotarised build record.');
  const expected = [`FreeTypist-${release.version}-arm64.dmg`, `FreeTypist-${release.version}-arm64.zip`];
  if (!Array.isArray(release.assets) || release.assets.length !== expected.length || !expected.every(file => release.assets.some(asset => asset.file === file))) throw new Error('Missing release assets.');
  for (const asset of release.assets) {
    const path = join(directory, asset.file);
    if ((await stat(path)).size !== asset.size || await hash(createReadStream(path)) !== asset.sha256) throw new Error(`Checksum mismatch: ${asset.file}`);
  }
  const installer = release.assets.find(asset => asset.file === release.file);
  if (installer.sha256 !== release.sha256 || installer.size !== release.size) throw new Error('Installer metadata does not match.');
  const feed = await readFile(join(directory, 'appcast.xml'), 'utf8');
  const archive = expected[1];
  if (!feed.includes(`https://type.cnnct.uk/releases/${archive}`) || !feed.includes('sparkle:edSignature=') || !feed.includes(`<sparkle:version>${release.build}</sparkle:version>`)) throw new Error('The signed appcast does not reference this release.');
  return release;
}

async function publish(directory) {
  const release = await readRelease(directory);
  const current = await fetch(`${origin}/mac.json`, { cache: 'no-store' });
  if (current.ok) {
    const previous = await current.json();
    if (!validRelease(previous) || !Number.isSafeInteger(previous.build)) throw new Error('Cannot verify current release.');
    if (previous.build > release.build) throw new Error('Refusing to replace a newer release.');
    if (previous.build === release.build && (previous.sha256 !== release.sha256 || JSON.stringify(previous.assets) !== JSON.stringify(release.assets))) throw new Error('This build is already published with different contents. Bump the version and build.');
  } else if (current.status !== 404) throw new Error(`Cannot check current release: HTTP ${current.status}`);

  const copy = (name, type, mutable = false) => execFileSync('mc', ['cp', '--quiet', '--attr', `Content-Type=${type};Cache-Control=${mutable ? 'no-store' : 'public,max-age=31536000,immutable'}`, join(directory, name), `${destination}/${name}`], { stdio: 'inherit' });
  for (const asset of release.assets) {
    const url = `${origin}/${asset.file}`;
    const existing = await fetch(url, { method: 'HEAD' });
    if (existing.status === 404) copy(asset.file, 'application/octet-stream');
    else if (!existing.ok) throw new Error(`Cannot check ${asset.file}: HTTP ${existing.status}`);
    const response = await fetch(url, { cache: 'no-store' });
    if (!response.ok || await hash(response.body) !== asset.sha256) throw new Error(`Public checksum mismatch: ${asset.file}. Feed not activated.`);
    await writeFile(join(directory, `${asset.file}.sha256`), `${asset.sha256}  ${asset.file}\n`);
    copy(`${asset.file}.sha256`, 'text/plain');
    console.log(`Verified ${asset.file}`);
  }
  // Activate only after all installers have been uploaded and read back in full.
  for (const [name, type] of [['appcast.xml', 'application/xml'], ['mac.json', 'application/json']]) {
    copy(name, type, true);
    const response = await fetch(`${origin}/${name}`, { cache: 'no-store' });
    if (!response.ok || await response.text() !== await readFile(join(directory, name), 'utf8')) throw new Error(`Cannot verify ${name}.`);
  }
  console.log(`Published FreeTypist ${release.version} (${release.build}) at https://type.cnnct.uk`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (!process.argv[2]) throw new Error('Usage: node Scripts/publish_release.mjs DIRECTORY (requires the existing mc brth alias)');
  await publish(resolve(process.argv[2]));
}
