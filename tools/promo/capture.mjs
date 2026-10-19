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
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// Serves tools/promo so the page can fetch its storyboard and fonts. Bound to 127.0.0.1, so only this
// machine can connect; paths that resolve outside tools/promo answer 404.
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.ttf': 'font/ttf' };
async function serve() {
  const server = createServer(async (req, res) => {
    try {
      const file = path.resolve(root, `.${decodeURIComponent(new URL(req.url, 'http://local').pathname)}`);
      if (!file.startsWith(root + path.sep)) throw new Error('outside tools/promo');
      const body = await readFile(file);
      res.writeHead(200, { 'content-type': TYPES[path.extname(file)] ?? 'application/octet-stream' }).end(body);
    } catch {
      res.writeHead(404).end();
    }
  }).listen(0, '127.0.0.1');
  await once(server, 'listening');
  return server;
}

// The render page, loaded and ready, in a 1920×1080 Chrome tab at device scale 1.
export async function openPromo({ chrome = CHROME } = {}) {
  const server = await serve();
  const url = `http://127.0.0.1:${server.address().port}`;
  const browser = await puppeteer.launch({
    executablePath: chrome,
    headless: true,
    defaultViewport: { width: 1920, height: 1080, deviceScaleFactor: 1 },
    args: ['--hide-scrollbars'],
  });
  const close = async () => { await browser.close(); server.close(); };
  try {
    const page = await browser.newPage();
    page.on('pageerror', err => { console.error(err); process.exitCode = 1; });
    await page.goto(`${url}/render/index.html`);
    const duration = await page.evaluate(async () => {
      await window.ready;
      await document.fonts.ready;
      return window.DURATION;
    });
    return { page, url, duration, close };
  } catch (err) {
    await close();
    throw err;
  }
}

if (import.meta.main) {
  const { values: opt } = parseArgs({
    options: {
      out: { type: 'string', default: path.join(root, 'out/frames') },
      from: { type: 'string', default: '0' },
      to: { type: 'string' },
      chrome: { type: 'string', default: CHROME },
    },
  });
  const seconds = flag => {
    const n = opt[flag].trim() === '' ? NaN : Number(opt[flag]);
    if (!Number.isFinite(n)) {
      console.error(`--${flag} must be a finite number of seconds, got "${opt[flag]}"`);
      process.exit(2);
    }
    return n;
  };
  const from = seconds('from'), to = opt.to === undefined ? undefined : seconds('to');
  const { page, duration, close } = await openPromo({ chrome: opt.chrome });
  try {
    const first = Math.round(from * FPS);
    const last = Math.round((to ?? duration) * FPS);
    await mkdir(opt.out, { recursive: true });
    for (let i = first; i < last; i++) {
      await page.evaluate(t => window.render(t), i / FPS);
      await page.screenshot({ path: path.join(opt.out, `frame-${String(i).padStart(5, '0')}.png`) });
    }
    console.log(JSON.stringify({ duration, frames: last - first }));
  } finally {
    await close();
  }
}
