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
