import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, readdir, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';

const capture = path.resolve(import.meta.dirname, '../capture.mjs');

async function run(...args) {
  const out = await mkdtemp(path.join(tmpdir(), 'promo-'));
  const { stdout } = await promisify(execFile)(process.execPath, [capture, '--out', out, ...args]);
  const frames = (await readdir(out)).filter(f => f.endsWith('.png')).sort();
  return { out, frames, summary: JSON.parse(stdout.trim().split('\n').at(-1)) };
}

const hashes = async ({ out, frames }) => Promise.all(frames.map(async f =>
  [f, createHash('sha256').update(await readFile(path.join(out, f))).digest('hex')]));

const twoSeconds = run('--from', '0', '--to', '2');

test('a 2 s slice gives exactly 60 frames', async () => {
  const { frames } = await twoSeconds;
  assert.equal(frames.length, 60);
  assert.equal(frames[0], 'frame-00000.png');
  assert.equal(frames.at(-1), 'frame-00059.png');
});

test('two captures of the same slice give identical SHA-256 hashes per frame', async () => {
  const [first, second] = await Promise.all([twoSeconds.then(hashes), run('--from', '0', '--to', '2').then(hashes)]);
  assert.deepEqual(second, first);
});

test('DURATION is 42–48 s', async () => {
  const { duration } = (await twoSeconds).summary;
  assert.ok(duration >= 42 && duration <= 48, `DURATION ${duration}`);
});

test('a frame rendered cold matches the same frame rendered mid-sequence', async () => {
  const cold = await run('--from', '1', '--to', String(1 + 1 / 30));
  assert.deepEqual(cold.frames, ['frame-00030.png']);
  const [[, coldHash]] = await hashes(cold);
  const sequential = new Map(await hashes(await twoSeconds));
  assert.equal(coldHash, sequential.get('frame-00030.png'));
});
