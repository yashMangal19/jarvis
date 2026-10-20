import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { gifCut } from '../encode.mjs';

const beats = JSON.parse(await readFile(path.resolve(import.meta.dirname, '../storyboard/beats.json'), 'utf8'));
const DURATION = beats.reduce((sum, b) => sum + b.secs, 0);

test('the GIF cut plays 10 s, and every segment fits inside DURATION', () => {
  const cut = gifCut(beats);
  const seconds = cut.reduce((sum, s) => sum + (s.to - s.from) / s.speed, 0);
  assert.ok(Math.abs(seconds - 10) < 1e-9, `the GIF plays ${seconds} s`);
  for (const s of cut) assert.ok(s.from >= 0 && s.from < s.to && s.to <= DURATION, JSON.stringify(s));
});

test('from the storyboard, the cut is the J-013 cut: 0–4, 25–32, 35–41, 43–45 and 3.8–4 s', () => {
  assert.deepEqual(gifCut(beats).map(s => [s.from, s.to, s.speed]),
    [[0, 4, 2], [25, 32, 1.75], [35, 41, 2], [43, 45, 2.5], [3.8, 4, 1]]);
});

test('a retimed storyboard moves the cut with it', () => {
  const longerCover = beats.map(b => (b.key === '01' ? { ...b, secs: 5 } : b));
  assert.deepEqual(gifCut(longerCover).map(s => [s.from, s.to]),
    [[0, 5], [26, 33], [36, 42], [44, 46], [4.8, 5]]);
});
