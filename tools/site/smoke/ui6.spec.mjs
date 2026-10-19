// Visual QA 4 (qa/visual-qa-4.md), S-1..S-8: geometry checks, each red before its fix. They measure boxes, lines and
// stroke, never pixels, and run at the widths where the bugs were found (961-1150) plus the widths that must not regress.
import { test, expect } from "./test.mjs";
import { readFileSync } from "node:fs";
import { NOW } from "../test/fixtures/clock.mjs";

const fixture = (name) => readFileSync(new URL(`../test/fixtures/status/${name}.json`, import.meta.url), "utf8");
const serve = (page) => page.route("https://raw.githubusercontent.com/**", (route) =>
  route.fulfill({ status: 200, body: fixture("fresh"), headers: { "access-control-allow-origin": "*" } }));

// Paused before goto, then fastForward: the page's own timers run once and nothing ticks behind the measurement.
async function open(page, width, height = 900) {
  await page.setViewportSize({ width, height });
  await serve(page);
  await page.clock.install({ time: NOW.getTime() - 1000 });
  await page.clock.pauseAt(NOW);
  await page.goto("/");
  await page.evaluate(() => document.fonts.ready);
  await page.clock.fastForward(3000);
  await page.waitForTimeout(450); // CSS transitions run on real time
}

// Box of an element, and of just its rendered text (not its padded slot) with the number of lines it takes.
const box = (locator) => locator.evaluate((el) => { const b = el.getBoundingClientRect(); return { left: b.left, top: b.top, right: b.right, bottom: b.bottom }; });
const ink = (locator) => locator.evaluate((el) => {
  const range = document.createRange();
  range.selectNodeContents(el);
  const rects = [...range.getClientRects()].filter((r) => r.width > 0);
  const b = range.getBoundingClientRect();
  return { left: b.left, right: b.right, top: b.top, bottom: b.bottom, lines: new Set(rects.map((r) => Math.round(r.top))).size };
});
const overlaps = (a, b, pad = 0) => a.left < b.right + pad && b.left < a.right + pad && a.top < b.bottom + pad && b.top < a.bottom + pad;
// Words on the last line of a wrapped paragraph (one text node or several).
const lastLineWords = (locator) => locator.evaluate((el) => {
  const words = [], walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    for (const m of n.data.matchAll(/\S+/g)) {
      const r = document.createRange(); r.setStart(n, m.index); r.setEnd(n, m.index + m[0].length);
      words.push(Math.round(r.getBoundingClientRect().top));
    }
  }
  const top = words.at(-1);
  return { lines: new Set(words).size, onLast: words.filter((t) => t === top).length };
});

test.beforeEach(({}, info) => test.skip(info.project.name === "phone", "each check sets its own viewport"));

const BAND = [961, 1024, 1100, 1150];

// S-1: the callout is drawn at the sheet's scale, so it never lands on a plate label. Each line of its text is a box turned by the
// callout's real 4deg tilt (about the callout's centre), and every label's box is tested against those turned boxes (separating
// axes), so a corner that only the tilt brings over a label is caught.
for (const width of [...BAND, 1280, 1440, 768]) {
  test(`S-1 p. 1: the callout, tilted as drawn, clears every plate label at ${width}`, async ({ page }) => {
    await open(page, width);
    const result = await page.locator("#p1 .callout").evaluate((el) => {
      const saved = el.style.transform;
      const m = new DOMMatrix(getComputedStyle(el).transform), angle = Math.atan2(m.b, m.a);
      el.style.transform = "none"; // lay it out flat; the box centre is the tilt's origin
      const flat = el.getBoundingClientRect(), cx = (flat.left + flat.right) / 2, cy = (flat.top + flat.bottom) / 2;
      const range = document.createRange();
      range.selectNodeContents(el);
      const lines = [...range.getClientRects()].filter((r) => r.width > 0);
      const labels = [...document.querySelectorAll("#p1 .plates .label")].map((l) => {
        const r = document.createRange(); r.selectNodeContents(l); const b = r.getBoundingClientRect();
        return { name: l.textContent.trim(), quad: [[b.left, b.top], [b.right, b.top], [b.right, b.bottom], [b.left, b.bottom]] };
      });
      const sheet = document.querySelector("#p1 .sheet").getBoundingClientRect();
      el.style.transform = saved;
      const turn = ([x, y]) => [cx + (x - cx) * Math.cos(angle) - (y - cy) * Math.sin(angle), cy + (x - cx) * Math.sin(angle) + (y - cy) * Math.cos(angle)];
      const quads = lines.map((r) => [[r.left, r.top], [r.right, r.top], [r.right, r.bottom], [r.left, r.bottom]].map(turn));
      const apart = (a, b) => { // separating axis test on two convex quads
        for (const poly of [a, b]) for (let i = 0; i < 4; i++) {
          const [x1, y1] = poly[i], [x2, y2] = poly[(i + 1) % 4], nx = y1 - y2, ny = x2 - x1;
          const range = (q) => q.map(([x, y]) => x * nx + y * ny);
          const ra = range(a), rb = range(b);
          if (Math.max(...ra) < Math.min(...rb) || Math.max(...rb) < Math.min(...ra)) return true;
        }
        return false;
      };
      return {
        touching: labels.filter((l) => quads.some((q) => !apart(q, l.quad))).map((l) => l.name),
        outside: quads.some((q) => q.some(([x, y]) => x > sheet.right || y > sheet.bottom)),
      };
    });
    expect(result.touching).toEqual([]);
    expect(result.outside).toBe(false);
  });
}

// S-2: the tick beside "tests green" is clear of the next stat's words, wherever the stats gap is narrow.
for (const width of [1440, 1280, 1150, 1100, 1024, 961, 768]) {
  test(`S-2 p. 3: the tests-green tick clears the next stat at ${width}`, async ({ page }) => {
    await open(page, width);
    const tick = await box(page.locator("#p3 .stat .tick"));
    const next = page.locator("#p3 .stat").nth(1);
    for (const part of [next.locator(".big"), next.locator(".hand:not(.big)")]) {
      expect(overlaps(tick, await ink(part), 4)).toBe(false);
    }
  });
}

// S-3: each strip's copy button stays on the strip's row.
for (const width of [...BAND, 1280, 1440]) {
  test(`S-3 p. 8: both copy buttons sit beside their strip at ${width}`, async ({ page }) => {
    await open(page, width);
    for (const strip of await page.locator("#p8 .strip").all()) {
      const code = await box(strip.locator("code")), copy = await box(strip.locator(".copy"));
      expect(copy.left).toBeGreaterThanOrEqual(code.right);
      expect(copy.top).toBeLessThan(code.bottom);
    }
  });
}

test("S-3 p. 8: --strip-chars is at least as long as the longest strip", async ({ page }) => {
  await open(page, 1440);
  const [token, longest] = await page.locator("#p8 .strips").evaluate((el) => [
    Number(getComputedStyle(el).getPropertyValue("--strip-chars")), Math.max(...[...el.querySelectorAll("code")].map((c) => c.textContent.length))]);
  expect(token).toBeGreaterThanOrEqual(longest);
});

// S-4: the countdown sits beside the gauge, and the clock is above the fold. Wider windows keep the full-size gauge.
for (const [width, height] of [...BAND.map((w) => [w, 768]), [1280, 800], [1440, 900]]) {
  test(`S-4 p. 1: the countdown sits beside the gauge at ${width}x${height}`, async ({ page }) => {
    await open(page, width, height);
    const gauge = await box(page.locator("#p1 .gauge")), clock = await ink(page.locator("#p1 .clock"));
    expect(clock.left).toBeGreaterThanOrEqual(gauge.right);
    expect(clock.bottom).toBeLessThanOrEqual(height);
  });
}
for (const [width, height] of [[1440, 700], [1280, 600], [1101, 800]]) {
  test(`S-4 p. 1: the smaller gauge is only for 961-1100px: ${width}x${height} keeps its full size`, async ({ page }) => {
    await open(page, width, height);
    expect((await box(page.locator("#p1 .gauge"))).right - (await box(page.locator("#p1 .gauge"))).left).toBeGreaterThanOrEqual(200 - 0.5);
  });
}

// S-5: the call-to-action is one line.
for (const width of [...BAND, 1280, 768]) {
  test(`S-5 p. 1: "watch it get built" is one line at ${width}`, async ({ page }) => {
    await open(page, width);
    expect((await ink(page.locator("#p1 .cta"))).lines).toBe(1);
  });
}

// F-3: the button keeps 26px everywhere except the narrow 961-1100px band, where it shrinks to stay on one line.
for (const width of [1440, 1280, 768, 390]) {
  test(`S-5 p. 1: the call-to-action is 26px at ${width}`, async ({ page }) => {
    await open(page, width);
    await expect(page.locator("#p1 .cta")).toHaveCSS("font-size", "26px");
  });
}

// S-6: every hand-drawn arrow is drawn at one weight. Each visible arrow (p. 2, p. 5's mic, wave and card arrows, p. 6's
// pipeline) is rasterised flat (its turn and its card's tilt removed) and the thickness of its shaft is measured from the pixels:
// the ink in each column (or row, for a vertical arrow) along the straight run at the tail's end of the shaft (before its first bend, where the drawing's two pen passes lie
// closest). The weights must agree.
async function arrowWeights(page, ids) {
  const analyser = await page.context().newPage();
  await analyser.setContent("<canvas></canvas>");
  const weights = {};
  const count = await page.evaluate(() => document.querySelectorAll(".pen, .arrow, .arrow-d, .arrow-r").length);
  const sel = ".pen, .arrow, .arrow-d, .arrow-r";
  const vis = { checkVisibilityCSS: true, visibilityProperty: true, opacityProperty: true };
  for (let n = 0; n < count + 8; n++) {
    // n < count: the n-th element; after that, the pipeline's pseudo-element arrows (li + li)
    const prep = await page.evaluate(([n, count, sel, vis]) => {
      let rect, name, undo = () => {};
      if (n < count) {
        const el = document.querySelectorAll(sel)[n];
        if (!el.checkVisibility(vis)) return null;
        const card = el.closest(".read-back"), saved = [el.style.rotate, card?.style.transform];
        el.style.rotate = "none"; if (card) card.style.transform = "none";
        undo = () => { el.style.rotate = saved[0]; if (card) card.style.transform = saved[1]; };
        el.scrollIntoView({ block: "center" });
        const b = el.getBoundingClientRect(); rect = { x: b.left, y: b.top, width: b.width, height: b.height };
        name = `${el.closest("section")?.id}:${el.className}`;
        if (el.closest(".mac")) return null; // never: the pipeline has no such element, only li::before
      } else {
        const li = document.querySelectorAll(".pipeline li")[n - count + 1];
        if (!li || !li.checkVisibility(vis)) return null;
        li.scrollIntoView({ block: "center" });
        const cs = getComputedStyle(li, "::before"), b = li.getBoundingClientRect();
        if (cs.content === "none") return null;
        rect = { x: b.left + parseFloat(cs.left), y: b.top + parseFloat(cs.top), width: parseFloat(cs.width), height: parseFloat(cs.height) };
        name = `p6:pipeline-${n - count + 1}`;
      }
      window.__undo = undo;
      return { rect, name };
    }, [n, count, sel, vis]);
    if (!prep) continue;
    await page.waitForTimeout(60);
    const png = await page.screenshot({ clip: prep.rect });
    await page.evaluate(() => window.__undo?.());
    weights[prep.name] = await analyser.evaluate(async ([b64, horizontal]) => {
      const img = new Image(); img.src = `data:image/png;base64,${b64}`; await img.decode();
      const c = document.querySelector("canvas"); c.width = img.width; c.height = img.height;
      const g = c.getContext("2d"); g.drawImage(img, 0, 0);
      const { data } = g.getImageData(0, 0, c.width, c.height);
      const lum = (x, y) => { const i = (y * c.width + x) * 4; return data[i]; }; // the red channel: graphite is dark in it, the page's red marks and paper are not
      const [from, to] = horizontal ? [0.12, 0.32] : [0.12, 0.45]; // before the first bend, where the two pen passes lie closest
      const along = horizontal ? c.width : c.height, across = horizontal ? c.height : c.width, INK = 45;
      const at = (a, b) => horizontal ? lum(a, b) : lum(b, a);
      const sums = [];
      for (let a = Math.floor(along * from); a <= Math.ceil(along * to); a++) {
        const edge = [0, 1, across - 2, across - 1].map((b) => at(a, b)).sort((p, q) => p - q), bg = (edge[1] + edge[2]) / 2;
        let sum = 0;
        for (let b = 0; b < across; b++) {
          const d = Math.min(1, Math.max(0, (bg - at(a, b)) / (bg - INK)));
          if (d > 0.6) sum += d; // the strong pen pass only: the faint second pass wanders with the arrow's length, the stroke does not
        }
        sums.push(sum);
      }
      return sums.reduce((p, q) => p + q, 0) / sums.length;
    }, [png.toString("base64"), prep.rect.width >= prep.rect.height]);
  }
  await analyser.close();
  return weights;
}
for (const width of [1440, 1024, 390]) {
  test(`S-6: every arrow on the page is drawn at one stroke weight at ${width}`, async ({ page }) => {
    await open(page, width);
    let all = await arrowWeights(page);
    await page.locator("#p5 [data-slot=slip][value=pricing]").click({ force: true }); // the answer card's arrow
    await page.clock.runFor(1500);
    await page.waitForTimeout(450);
    all = { ...all, ...Object.fromEntries(Object.entries(await arrowWeights(page)).map(([k, v]) => [`pricing ${k}`, v])) };
    const values = Object.values(all);
    expect(values.length, JSON.stringify(all)).toBeGreaterThanOrEqual(width === 1440 ? 8 : 4);
    const mid = [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
    for (const [name, w] of Object.entries(all)) expect(Math.abs(w - mid), `${name} ${w.toFixed(2)}px against ${mid.toFixed(2)}px (${JSON.stringify(all)})`).toBeLessThan(0.4);
    expect(mid).toBeGreaterThan(1.5); // it is drawn, not absent
  });
}

// S-7: the poster's own box is the video's (the figure is not stretched past it), so the play button's fixed place in
// the poster's empty band holds at any width: above the "not affiliated" line, which is at 87-89.5% of the poster.
for (const width of [...BAND, 1280, 1440, 768]) {
  test(`S-7 p. 2: the play button clears the poster's disclaimer at ${width}`, async ({ page }) => {
    await open(page, width);
    const player = await box(page.locator("#p2 .player")), video = await box(page.locator("#p2 video")), play = await box(page.locator("#p2 .play"));
    expect(player.bottom - video.bottom).toBeLessThan(4);
    expect(play.bottom).toBeLessThan(video.top + (video.bottom - video.top) * 0.87);
  });
}

// S-8: no pipeline caption leaves one word alone on its last line.
for (const width of [...BAND, 1280, 1440, 768]) {
  test(`S-8 p. 6: no caption ends on a lone word at ${width}`, async ({ page }) => {
    await open(page, width);
    for (const p of await page.locator("#p6 .pipeline p").all()) {
      const { lines, onLast } = await lastLineWords(p);
      if (lines > 1) expect(onLast, await p.textContent()).toBeGreaterThan(1);
    }
  });
}
