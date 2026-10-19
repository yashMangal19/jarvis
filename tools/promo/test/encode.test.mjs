import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';

const exec = promisify(execFile);
const here = path.resolve(import.meta.dirname, '..');

// A 2 s fixture capture (60 frames), encoded into a temp media folder.
const encoded = (async () => {
  const frames = await mkdtemp(path.join(tmpdir(), 'promo-frames-'));
  const out = await mkdtemp(path.join(tmpdir(), 'promo-media-'));
  await exec(process.execPath, [path.join(here, 'capture.mjs'), '--out', frames, '--from', '0', '--to', '2']);
  await exec(process.execPath, [path.join(here, 'encode.mjs'), '--frames', frames, '--out', out]);
  return { frames, out };
})();

const probe = async file => JSON.parse((await exec('ffprobe',
  ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', file])).stdout);

test('the MP4 is 30 fps, 1920×1080 H.264 with no audio stream', async () => {
  const { streams } = await probe(path.join((await encoded).out, 'promo.mp4'));
  assert.deepEqual(streams.map(s => s.codec_type), ['video']);
  const [v] = streams;
  assert.equal(v.codec_name, 'h264');
  assert.equal(v.pix_fmt, 'yuv420p');
  assert.equal(`${v.width}×${v.height}`, '1920×1080');
  assert.equal(v.r_frame_rate, '30/1');
  assert.equal(Number(v.nb_frames), 60);
});

test('the GIF exists, 720 px wide at 15 fps; a 2 s capture gives only beat 1 at double speed, so 1 s', async () => {
  const { streams: [g], format } = await probe(path.join((await encoded).out, 'promo.gif'));
  assert.equal(g.codec_name, 'gif');
  assert.equal(g.width, 720);
  assert.equal(g.r_frame_rate, '15/1');
  assert.equal(Number(format.duration), 1);
});

test('the poster is the last captured frame', async () => {
  const { frames, out } = await encoded;
  assert.deepEqual(await readFile(path.join(out, 'poster.png')), await readFile(path.join(frames, 'frame-00059.png')));
});

test('encode refuses frames that do not run unbroken from frame-00000, and names the first gap', async () => {
  const frames = await mkdtemp(path.join(tmpdir(), 'promo-gap-'));
  await exec('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=64x36:rate=30', '-frames:v', '6', '-start_number', '0',
    path.join(frames, 'frame-%05d.png')]);
  await rm(path.join(frames, 'frame-00003.png'));
  const out = await mkdtemp(path.join(tmpdir(), 'promo-media-'));
  await assert.rejects(exec(process.execPath, [path.join(here, 'encode.mjs'), '--frames', frames, '--out', out]),
    err => /frame-00003\.png/.test(err.stderr));
  assert.deepEqual(await readdir(out), []);
});
