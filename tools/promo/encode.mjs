// Encodes captured frames into the site's media: promo.mp4, the 10 s README GIF and poster.png.
// node encode.mjs [--capture] [--frames dir] [--out dir]   (ffmpeg must be on PATH)
import { execFile } from 'node:child_process';
import { copyFile, mkdir, readdir } from 'node:fs/promises';
import path from 'node:path';
import { parseArgs, promisify } from 'node:util';

const FPS = 30;
const exec = promisify(execFile);
const root = import.meta.dirname;
const { values: opt } = parseArgs({
  options: {
    capture: { type: 'boolean', default: false },
    frames: { type: 'string', default: path.join(root, 'out/frames') },
    out: { type: 'string', default: path.join(root, '../../docs/media') },
  },
});

// The GIF's 10 s cut (J-013 Log, "the 10-second GIF"): source seconds [from, to) played `speed`× faster.
// 0–2 s beat 1 · 2–6 s beats 6a+6b · 6–9 s beat 8 · 9–9.8 s beat 9 (ends fully drawn) ·
// 9.8–10 s the finished cover, so the loop cuts back to it.
const GIF_CUT = [
  { from: 0, to: 4, speed: 2 },
  { from: 25, to: 32, speed: 1.75 },
  { from: 35, to: 41, speed: 2 },
  { from: 43, to: 45, speed: 2.5 },
  { from: 3.8, to: 4, speed: 1 },
];

if (opt.capture) {
  await exec(process.execPath, [path.join(root, 'capture.mjs'), '--out', opt.frames]);
}
const frames = (await readdir(opt.frames)).filter(f => /^frame-\d{5}\.png$/.test(f)).sort();
const duration = frames.length / FPS;
await mkdir(opt.out, { recursive: true });
const input = ['-framerate', String(FPS), '-i', path.join(opt.frames, 'frame-%05d.png')];
const ffmpeg = (...args) => exec('ffmpeg', ['-v', 'error', '-y', ...input, ...args]);

await ffmpeg('-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-an', '-movflags', '+faststart',
  path.join(opt.out, 'promo.mp4'));

// fps per segment, not after the concat: resampled after it, the joins lose the GIF's last frame.
// A shorter capture (the 2 s test fixture) keeps only the parts of the cut it has.
const cut = GIF_CUT.filter(s => s.from < duration).map(s => ({ ...s, to: Math.min(s.to, duration) }));
const graph = [
  `[0:v]split=${cut.length}${cut.map((_, i) => `[in${i}]`).join('')}`,
  ...cut.map((s, i) => `[in${i}]trim=start=${s.from}:end=${s.to},setpts=(PTS-STARTPTS)/${s.speed},fps=15[s${i}]`),
  `${cut.map((_, i) => `[s${i}]`).join('')}concat=n=${cut.length}:v=1:a=0,scale=720:-1:flags=lanczos,split[a][b]`,
  '[a]palettegen[p]',
  '[b][p]paletteuse',
].join(';');
await ffmpeg('-filter_complex', graph, path.join(opt.out, 'promo.gif'));

await copyFile(path.join(opt.frames, frames.at(-1)), path.join(opt.out, 'poster.png'));
