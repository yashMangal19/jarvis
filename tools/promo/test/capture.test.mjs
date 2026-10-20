import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cp, mkdtemp, readdir, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { openPromo } from '../capture.mjs';

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

test('every text stays inside the 60 px frame margin, and inside its w, at its beat\'s end frame', async () => {
  const beats = JSON.parse(await readFile(path.resolve(import.meta.dirname, '../storyboard/beats.json'), 'utf8'));
  const { page, close } = await openPromo();
  try {
    let end = 0;
    for (const beat of beats) {
      end += beat.secs;
      const boxes = await page.evaluate(t => {
        window.render(t);
        return [...document.querySelectorAll('.beat:not([hidden]) .txt')].map(el => {
          const { left, top, right, bottom, width } = el.getBoundingClientRect();
          return { text: el.textContent, left, top, right, bottom, width };
        });
      }, end - 1 / 30);
      for (const spec of beat.texts) {
        const box = boxes.find(b => b.text === spec.t);
        const where = `beat ${beat.key} "${spec.t}" ${JSON.stringify(box)}`;
        assert.ok(box.left >= 60 && box.top >= 60 && box.right <= 1860 && box.bottom <= 1020, where);
        if (spec.w) assert.ok(box.width <= spec.w, where);
      }
    }
  } finally {
    await close();
  }
});

test('the capture server answers 404 for any path outside tools/promo', async () => {
  const { url, close } = await openPromo();
  try {
    assert.equal((await fetch(`${url}/render/index.html`)).status, 200);
    for (const escape of ['/..%2F..%2Fetc%2Fhosts', `/${'..%2F'.repeat(20)}etc%2Fhosts`]) {
      assert.equal((await fetch(url + escape)).status, 404, escape);
    }
  } finally {
    await close();
  }
});

test('a non-finite --from or --to exits non-zero', async () => {
  for (const args of [['--from', 'abc'], ['--to', 'Infinity'], ['--from', '']]) {
    await assert.rejects(run(...args), err => err.code !== 0, args.join(' '));
  }
});

test('no beat\'s caption repeats a line already drawn in that beat', async () => {
  const beats = JSON.parse(await readFile(path.resolve(import.meta.dirname, '../storyboard/beats.json'), 'utf8'));
  const { page, close } = await openPromo();
  try {
    let end = 0;
    for (const beat of beats) {
      end += beat.secs;
      const caption = await page.evaluate(t => {
        window.render(t);
        return document.getElementById('caption').textContent;
      }, end - 1 / 30);
      assert.ok(!beat.texts.some(s => s.t === caption), `beat ${beat.key} caption "${caption}"`);
    }
  } finally {
    await close();
  }
});

test('a capture replaces the frames already in --out, and leaves other files there alone', async () => {
  const { out } = await twoSeconds;
  const again = path.join(out, '..', `${path.basename(out)}-again`);
  await cp(out, again, { recursive: true });
  await writeFile(path.join(again, 'notes.txt'), 'keep me');
  await promisify(execFile)(process.execPath, [capture, '--out', again, '--from', '1', '--to', String(1 + 1 / 30)]);
  assert.deepEqual((await readdir(again)).sort(), ['frame-00030.png', 'notes.txt']);
});
