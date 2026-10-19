// Saves the promo as one PNG per frame: render(i/30), then screenshot, in a local Chrome.
// node capture.mjs [--out dir] [--from s] [--to s] [--chrome path]   → <out>/frame-%05d.png
import puppeteer from 'puppeteer-core';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { mkdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { parseArgs } from 'node:util';

const FPS = 30;
const root = import.meta.dirname;
const { values: opt } = parseArgs({
  options: {
    out: { type: 'string', default: path.join(root, 'out/frames') },
    from: { type: 'string', default: '0' },
    to: { type: 'string' },
    chrome: { type: 'string', default: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' },
  },
});

// Loopback only, so the page can fetch its storyboard and fonts. Nothing reaches the network.
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.ttf': 'font/ttf' };
const server = createServer(async (req, res) => {
  const file = path.join(root, decodeURIComponent(new URL(req.url, 'http://local').pathname));
  try {
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': TYPES[path.extname(file)] ?? 'application/octet-stream' }).end(body);
  } catch {
    res.writeHead(404).end();
  }
}).listen(0, '127.0.0.1');
await once(server, 'listening');

const browser = await puppeteer.launch({
  executablePath: opt.chrome,
  headless: true,
  defaultViewport: { width: 1920, height: 1080, deviceScaleFactor: 1 },
  args: ['--hide-scrollbars'],
});
try {
  const page = await browser.newPage();
  page.on('pageerror', err => { console.error(err); process.exitCode = 1; });
  await page.goto(`http://127.0.0.1:${server.address().port}/render/index.html`);
  const duration = await page.evaluate(async () => {
    await window.ready;
    await document.fonts.ready;
    return window.DURATION;
  });
  const first = Math.round(Number(opt.from) * FPS);
  const last = Math.round(Number(opt.to ?? duration) * FPS);
  await mkdir(opt.out, { recursive: true });
  for (let i = first; i < last; i++) {
    await page.evaluate(t => window.render(t), i / FPS);
    await page.screenshot({ path: path.join(opt.out, `frame-${String(i).padStart(5, '0')}.png`) });
  }
  console.log(JSON.stringify({ duration, frames: last - first }));
} finally {
  await browser.close();
  server.close();
}
