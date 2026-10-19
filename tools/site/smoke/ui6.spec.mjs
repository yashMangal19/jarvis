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

// S-1: the callout is drawn at the sheet's scale, so it never lands on a plate label.
for (const width of [...BAND, 1280, 1440, 768]) {
  test(`S-1 p. 1: the callout clears every plate label at ${width}`, async ({ page }) => {
    await open(page, width);
    // Line by line and untilted: the 4deg tilt makes each line's bounding box taller than its text, so the tilted boxes
    // touch a label that the words never come near (the tilt is about the centre, where the labels sit).
    const lines = await page.locator("#p1 .callout").evaluate((el) => {
      el.style.transform = "none";
      const range = document.createRange();
      range.selectNodeContents(el);
      return [...range.getClientRects()].filter((r) => r.width > 0).map((r) => ({ left: r.left, right: r.right, top: r.top, bottom: r.bottom }));
    });
    const sheet = await box(page.locator("#p1 .sheet"));
    for (const label of await page.locator("#p1 .plates .label").all()) {
      const l = await ink(label);
      for (const line of lines) expect(overlaps(line, l), await label.textContent()).toBe(false);
    }
    expect(Math.max(...lines.map((l) => l.right))).toBeLessThanOrEqual(sheet.right);
    expect(Math.max(...lines.map((l) => l.bottom))).toBeLessThanOrEqual(sheet.bottom);
  });
}

// S-2: the tick beside "tests green" is clear of the next stat's words, wherever the stats gap is narrow.
for (const width of [1440, 1280, 1024, 768]) {
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

// S-4: the countdown sits beside the gauge, and the clock is above the fold of a 1024x768 window.
for (const width of BAND) {
  test(`S-4 p. 1: the countdown sits beside the gauge at ${width}`, async ({ page }) => {
    await open(page, width, 768);
    const gauge = await box(page.locator("#p1 .gauge")), clock = await ink(page.locator("#p1 .clock"));
    expect(clock.left).toBeGreaterThanOrEqual(gauge.right);
    expect(clock.bottom).toBeLessThanOrEqual(768);
  });
}

// S-5: the call-to-action is one line.
for (const width of [...BAND, 1280, 768]) {
  test(`S-5 p. 1: "watch it get built" is one line at ${width}`, async ({ page }) => {
    await open(page, width);
    expect((await ink(page.locator("#p1 .cta"))).lines).toBe(1);
  });
}

// S-6: the two card arrows are drawn at one weight. The shaft's stroke does not scale with its length and the head is a
// fixed size, so a long arrow is longer, not heavier.
for (const width of [1440, 1024]) {
  test(`S-6 p. 5: the pricing arrow and the read-back arrow share one stroke and head at ${width}`, async ({ page }) => {
    await open(page, width);
    await page.locator("#p5 [data-slot=slip][value=pricing]").click();
    await page.clock.runFor(1500);
    await page.waitForTimeout(450);
    const parts = await page.locator("#p5").evaluate(async (sec) => {
      const out = {};
      for (const slot of ["read-back", "answer"]) {
        const arrow = sec.querySelector(`[data-slot=${slot}] .to-card`);
        const head = arrow.querySelector("img.head"), shaft = arrow.querySelector("img:not(.head)");
        out[slot] = { length: arrow.offsetWidth, head: head ? head.offsetWidth : null, shaft: shaft ? await (await fetch(shaft.src)).text() : "" };
      }
      return out;
    });
    expect(parts["read-back"].length).not.toBe(parts.answer.length); // the lengths do differ: that is the point
    expect(parts["read-back"].head).not.toBeNull();
    expect(parts["read-back"].head).toBe(parts.answer.head);
    for (const slot of ["read-back", "answer"]) {
      const paths = parts[slot].shaft.match(/<path[^>]*>/g) ?? [];
      expect(paths.length).toBeGreaterThan(0);
      for (const p of paths) expect(p).toContain('vector-effect="non-scaling-stroke"');
    }
  });
}

// S-7: the poster's own box is the video's (the figure is not stretched past it), so the play button's fixed place in
// the poster's empty band holds at any width: above the "not affiliated" line, which is at 87-89.5% of the poster.
for (const width of [...BAND, 1440, 768]) {
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
