// Measurable layout checks from visual QA round 1 (qa/visual-qa-1.md): each one failed before its fix.
import { test, expect } from "./test.mjs";
import { readFileSync } from "node:fs";
import { NOW } from "../test/fixtures/clock.mjs";

const STATUS = "https://raw.githubusercontent.com/yashMangal19/jarvis/status/status.json?*";
const FRESH = readFileSync(new URL("../test/fixtures/status/fresh.json", import.meta.url), "utf8");

async function open(page) {
  await page.route(STATUS, (route) => route.fulfill({ status: 200, body: FRESH, headers: { "access-control-allow-origin": "*" } }));
  await page.clock.install({ time: NOW.getTime() - 1000 });
  await page.clock.pauseAt(NOW);
  await page.goto("/");
  await page.evaluate(() => document.fonts.ready);
}

// The box of an element's rendered text (not its padded slot), and the number of lines it takes.
const ink = (locator) => locator.evaluate((el) => {
  const range = document.createRange();
  range.selectNodeContents(el);
  const rects = [...range.getClientRects()].filter((r) => r.width > 0);
  const tops = new Set(rects.map((r) => Math.round(r.top)));
  const b = range.getBoundingClientRect();
  return { left: b.left, right: b.right, top: b.top, bottom: b.bottom, lines: tops.size };
});
const overlaps = (a, b) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;

const p1 = (page) => page.locator("#p1");

for (const width of [1440, 1280, 768]) {
  test.describe(`${width} px`, () => {
    test.use({ viewport: { width, height: 900 } });
    test("p. 1: the gauge's 'online!' never covers the countdown or the date", async ({ page }, info) => {
      test.skip(info.project.name !== "desktop", "the viewport is set here");
      await open(page);
      const online = await ink(p1(page).locator(".gauge figcaption .red"));
      for (const sel of [".when", "[data-slot=launch-line]", ".clock"]) {
        expect(overlaps(online, await ink(p1(page).locator(sel))), sel).toBe(false);
      }
    });
  });
}

test("p. 1: the countdown starts flush with its label", async ({ page }) => {
  await open(page);
  const clock = await ink(p1(page).locator("[data-slot=days]")); // the first digit, not its slot
  const label = await ink(p1(page).locator("[data-slot=launch-line]"));
  expect(Math.abs(clock.left - label.left)).toBeLessThanOrEqual(4);
});

test("p. 3: the tests-green number starts flush with its label", async ({ page }) => {
  await open(page);
  const stat = page.locator("#p3 .stat").first();
  const big = await ink(stat.locator(".big"));
  const label = await ink(stat.locator(".hand:not(.big)"));
  expect(Math.abs(big.left - label.left)).toBeLessThanOrEqual(6);
});

test("p. 1: the gauge and the countdown sit above the fold", async ({ page }, info) => {
  test.skip(info.project.name !== "desktop", "1440×900 only");
  await open(page);
  for (const sel of [".gauge", ".countdown .clock", ".when"]) {
    const box = await p1(page).locator(sel).boundingBox();
    expect(box.y + box.height, sel).toBeLessThanOrEqual(900);
  }
});

test("p. 3: every commit age reads on one line", async ({ page }) => {
  await open(page);
  for (const age of await page.locator("#p3 [data-slot=commit-age]").all()) {
    if (await age.textContent()) expect((await ink(age)).lines).toBe(1);
  }
});

test("p. 6: each plate's line reads on one line", async ({ page }, info) => {
  test.skip(info.project.name !== "desktop", "the desktop row only");
  await open(page);
  for (const p of await page.locator("#p6 .pipeline p").all()) expect((await ink(p)).lines, await p.textContent()).toBe(1);
});

test("p. 8: 'this slot is yours →' reads on one line", async ({ page }) => {
  await open(page);
  expect((await ink(page.locator("#p8 .slot-yours figcaption"))).lines).toBe(1);
});

const desktopOnly = (info) => test.skip(info.project.name !== "desktop", "1440×900 only");
const phoneOnly = (info) => test.skip(info.project.name !== "phone", "390×844 only");

test("p. 1: the blueprint sheet sits where D1 has it (left ≈612, width ≈790)", async ({ page }, info) => {
  desktopOnly(info);
  await open(page);
  const box = await p1(page).locator(".sheet").boundingBox();
  expect(Math.abs(box.x - 612), `left ${box.x}`).toBeLessThanOrEqual(24);
  expect(Math.abs(box.width - 790), `width ${box.width}`).toBeLessThanOrEqual(30);
});

test("p. 1: on the phone, one tape top-left, one bottom-right, and the button right under the countdown", async ({ page }, info) => {
  phoneOnly(info);
  await open(page);
  const sheet = await p1(page).locator(".sheet").boundingBox();
  const tapes = [];
  for (const t of await p1(page).locator(".sheet .tape").all()) if (await t.isVisible()) tapes.push(await t.boundingBox());
  expect(tapes).toHaveLength(2);
  const mid = (b) => ({ x: b.x + b.width / 2, y: b.y + b.height / 2 });
  const [a, b] = tapes.map(mid).sort((p, q) => p.y - q.y);
  expect(a.x).toBeLessThan(sheet.x + sheet.width / 2); // top tape on the left half
  expect(a.y).toBeLessThan(sheet.y + 40);
  expect(b.x).toBeGreaterThan(sheet.x + sheet.width / 2); // bottom tape on the right half
  expect(b.y).toBeGreaterThan(sheet.y + sheet.height - 40);
  const countdown = await ink(p1(page).locator(".countdown .line"));
  const cta = await p1(page).locator(".cta").boundingBox();
  expect(cta.y - countdown.bottom).toBeLessThanOrEqual(40);
});

// The red tick's own extent, read from the drawing, in page pixels.
const tickRight = (img) => img.evaluate(async (el) => {
  const svg = new DOMParser().parseFromString(await (await fetch(el.src)).text(), "image/svg+xml").documentElement;
  const host = document.body.appendChild(document.createElementNS("http://www.w3.org/2000/svg", "svg"));
  host.append(...svg.childNodes);
  const red = [...host.querySelectorAll("path")].find((p) => p.getAttribute("stroke") === "#C8302A");
  const bb = red.getBBox();
  const right = bb.x + bb.width + Number(red.getAttribute("stroke-width")) / 2;
  host.remove();
  const r = el.getBoundingClientRect();
  return r.left + right * (r.width / svg.viewBox.baseVal.width);
});

test("p. 3: wave boxes are at least 48px and no tick crosses into the next box", async ({ page }, info) => {
  desktopOnly(info);
  await open(page);
  const imgs = await page.locator("#p3 [data-slot=wave-boxes] img").all();
  const cells = [];
  for (const img of imgs) cells.push(await img.locator("xpath=..").boundingBox());
  for (const [i, img] of imgs.entries()) {
    expect(cells[i].width, `cell ${i}`).toBeGreaterThanOrEqual(48);
    if (i + 1 < imgs.length && (await img.getAttribute("src")).endsWith("box-tick.svg")) {
      expect(await tickRight(img), `tick ${i}`).toBeLessThanOrEqual(cells[i + 1].x);
    }
  }
  expect(cells[1].x - (cells[0].x + cells[0].width), "a small gap between boxes").toBeGreaterThan(0);
});

test("p. 7: one continuous shelf under the cases and the marks", async ({ page }, info) => {
  desktopOnly(info);
  await open(page);
  const segments = await page.locator("#p7 .case").evaluateAll((cases) => cases.flatMap((c) => {
    const r = c.getBoundingClientRect();
    const out = [];
    if (parseFloat(getComputedStyle(c).borderBottomWidth) > 0) out.push([r.left, r.right]);
    const after = getComputedStyle(c, "::after");
    if (after.content !== "none" && parseFloat(after.borderBottomWidth) > 0) out.push([r.left, r.left + parseFloat(after.width)]);
    return out;
  }).sort((a, b) => a[0] - b[0]));
  expect(segments.length).toBeGreaterThan(0);
  for (let i = 1; i < segments.length; i++) expect(segments[i][0], `gap before segment ${i}`).toBeLessThanOrEqual(segments[i - 1][1]);
  const marks = await page.locator("#p7 .marks").boundingBox();
  expect(Math.max(...segments.map((s) => s[1]))).toBeGreaterThanOrEqual(marks.x + marks.width - 8);
});

test("p. 6: on the phone, icons are at least 76px and names at least 30px", async ({ page }, info) => {
  phoneOnly(info);
  await open(page);
  for (const img of await page.locator("#p6 .pipeline img").all()) expect((await img.boundingBox()).width).toBeGreaterThanOrEqual(76);
  for (const h of await page.locator("#p6 .pipeline h3").all()) {
    expect(parseFloat(await h.evaluate((el) => getComputedStyle(el).fontSize))).toBeGreaterThanOrEqual(30);
  }
});

test("header: the phone menu links are not underlined", async ({ page }, info) => {
  phoneOnly(info);
  await open(page);
  await page.locator(".nav-phone summary").click();
  for (const a of await page.locator(".nav-phone nav a").all()) await expect(a).toHaveCSS("text-decoration-line", "none");
});

test("p. 2: 'no sound' stays clear of the poster's headline and stamp", async ({ page }) => {
  await open(page);
  const player = await page.locator("#p2 .player video").boundingBox();
  const label = await page.locator("#p2 .player-label").boundingBox();
  // media/poster.png (1920×1080): the headline and the mit stamp, as fractions of the frame.
  const regions = [[0.165, 0.28, 0.74, 0.43], [0.72, 0.16, 0.86, 0.39]].map(([l, t, r, b]) => ({
    left: player.x + l * player.width, top: player.y + t * player.height,
    right: player.x + r * player.width, bottom: player.y + b * player.height,
  }));
  const box = { left: label.x, top: label.y, right: label.x + label.width, bottom: label.y + label.height };
  for (const r of regions) expect(overlaps(box, r), JSON.stringify(r)).toBe(false);
});

test("p. 1: the countdown's letters hold still when minutes go from 10 to 9", async ({ page }) => {
  await page.route(STATUS, (route) => route.fulfill({ status: 200, body: FRESH, headers: { "access-control-allow-origin": "*" } }));
  const t = new Date("2026-10-19T20:49:30+05:30"); // 10 m 30 s before the 9 pm launch
  await page.clock.install({ time: t.getTime() - 1000 });
  await page.clock.pauseAt(t);
  await page.goto("/");
  await page.evaluate(() => document.fonts.ready);
  const minutes = p1(page).locator("[data-slot=minutes]");
  const mLeft = () => minutes.evaluate((el) => {
    const r = document.createRange();
    r.setStart(el.nextSibling, 0); r.setEnd(el.nextSibling, 1); // the "m" after the minutes
    return r.getBoundingClientRect().left;
  });
  await expect(minutes).toHaveText("10");
  const before = await mLeft();
  await page.clock.fastForward(60e3);
  await expect(minutes).toHaveText("9");
  expect(await mLeft()).toBeCloseTo(before, 0);
});

test.describe("1280×800", () => {
  test.use({ viewport: { width: 1280, height: 800 } });
  test("p. 1: the gauge and the countdown sit above the fold", async ({ page }, info) => {
    desktopOnly(info);
    await open(page);
    for (const sel of [".gauge", ".countdown .clock", ".when"]) {
      const box = await p1(page).locator(sel).boundingBox();
      expect(box.y + box.height, sel).toBeLessThanOrEqual(800);
    }
  });
});

test("p. 2: on the phone the player keeps one tape, top-left (M2)", async ({ page }, info) => {
  phoneOnly(info);
  await open(page);
  const player = await page.locator("#p2 .player").boundingBox();
  const tapes = [];
  for (const t of await page.locator("#p2 .player .tape").all()) if (await t.isVisible()) tapes.push(await t.boundingBox());
  expect(tapes).toHaveLength(1);
  expect(tapes[0].x + tapes[0].width / 2).toBeLessThan(player.x + player.width / 2);
  expect(tapes[0].y).toBeLessThan(player.y + 20);
});

test("p. 2: before play, a clean frame with one big play button; the controls come with playback", async ({ page }) => {
  await open(page);
  const video = page.locator("#p2 video");
  const play = page.getByRole("button", { name: "play the promo" });
  await expect(play).toBeVisible();
  await expect(video).not.toHaveAttribute("controls");
  expect(await video.evaluate((v) => v.paused)).toBe(true);
  await play.focus();
  await page.keyboard.press("Enter");
  await expect(video).toHaveAttribute("controls", "");
  await expect(play).toBeHidden();
  await video.evaluate((v) => v.pause());
  await expect(video).toHaveAttribute("controls", ""); // kept after playback starts
});

test.describe("reduced motion", () => {
  test.use({ reducedMotion: "reduce" });
  test("p. 2: the promo never plays by itself", async ({ page }) => {
    await open(page);
    await page.waitForTimeout(500);
    expect(await page.locator("#p2 video").evaluate((v) => v.paused && v.currentTime === 0)).toBe(true);
    await expect(page.getByRole("button", { name: "play the promo" })).toBeVisible();
  });
});
