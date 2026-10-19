import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";
import { NOW } from "../test/fixtures/clock.mjs";

const STATUS = "https://raw.githubusercontent.com/yashMangal19/jarvis/status/status.json?*";
const fixture = (name) =>
  readFileSync(new URL(`../test/fixtures/status/${name}.json`, import.meta.url), "utf8");
const LATE = new Date("2026-10-20T01:30:00+05:30");

// null serves a 404, as a missing status file does.
async function serve(page, body) {
  await page.route(STATUS, (route) => route.fulfill(body === null
    ? { status: 404, body: "404: Not Found" }
    : { status: 200, body, headers: { "access-control-allow-origin": "*" } }));
}

async function open(page, body, time = NOW) {
  await serve(page, body);
  // Paused at exactly `time`, so a few real ms cannot turn 9 h 0 m into 8 h 59 m; fastForward drives it.
  await page.clock.install({ time: time.getTime() - 1000 });
  await page.clock.pauseAt(time);
  await page.goto("/");
}

const p1 = (page) => page.locator("#p1");
const slot = (page, name) => p1(page).locator(`[data-slot="${name}"]`);
const clock = (page) => ["days", "hours", "minutes"].map((n) => slot(page, n));

async function expectClock(page, d, h, m) {
  const [days, hours, minutes] = clock(page);
  await expect(days).toHaveText(d);
  await expect(hours).toHaveText(h);
  await expect(minutes).toHaveText(m);
}

test("before the deadline: the countdown shows 0 d 9 h 0 m", async ({ page }) => {
  await open(page, fixture("fresh"));
  await expectClock(page, "0", "9", "0");
  await expect(slot(page, "launch-line")).toHaveText("till it goes online");
});

test("missing status: the countdown still runs, ticking on the minute", async ({ page }) => {
  await open(page, null, new Date("2026-10-19T12:00:30+05:30"));
  await expectClock(page, "0", "8", "59");
  await page.clock.fastForward(31e3); // past 12:01:00 → 8 h 58 m 59 s left
  await expectClock(page, "0", "8", "58");
  await page.clock.fastForward(60e3);
  await expectClock(page, "0", "8", "57");
});

const LOG = ["waves-done", "waves-total", "tests-green", "last-commit-age"];

test("build log: waves, tests green and the last commit's age", async ({ page }) => {
  await open(page, fixture("fresh"));
  await expect(slot(page, "waves-done")).toHaveText("8");
  await expect(slot(page, "waves-total")).toHaveText("10");
  await expect(slot(page, "tests-green")).toHaveText("287");
  await expect(slot(page, "last-commit-age")).toHaveText("48m ago");
});

test("build log: dashed empties when the status is missing", async ({ page }) => {
  await open(page, null);
  await expect(p1(page)).toHaveAttribute("data-state", "countdown");
  for (const name of LOG) await expect(slot(page, name)).toHaveText("");
});

const live = (page) => p1(page).locator('[aria-live="polite"]');

test("late + qa: running late by 4 h and the qa reason, no art, no countdown", async ({ page }) => {
  await open(page, fixture("late-qa"), LATE);
  await expect(slot(page, "launch-line")).toHaveText("running late by 4 h · Final checks 70/88");
  await expect(slot(page, "reason-line")).toHaveText("still checking every bolt by hand.");
  await expect(live(page).locator('[data-slot="reason-line"]')).toBeVisible();
  await expect(slot(page, "busy-art")).toBeHidden();
  await expect(p1(page).locator(".clock")).toBeHidden();
});

test("late + busy: the busy reason and the flip-book playing", async ({ page }) => {
  await open(page, fixture("late-busy"), LATE);
  await expect(slot(page, "reason-line")).toHaveText("yash got pulled away. jarvis waits for him.");
  const art = slot(page, "busy-art");
  await expect(art).toBeVisible();
  await expect(art).toHaveCSS("animation-name", "busy");
  await expect(art).toHaveCSS("background-image", /busy-sprite\.svg/);
});

test.describe("reduced motion", () => {
  test.use({ reducedMotion: "reduce" });
  test("late + busy: the still frame, and no animation runs", async ({ page }) => {
    await open(page, fixture("late-busy"), LATE);
    const art = slot(page, "busy-art");
    await expect(art).toBeVisible();
    await expect(art).toHaveCSS("animation-name", "none");
    await expect(art).toHaveCSS("background-image", /busy-01\.svg/);
  });
});

test("late with a reason of null: no reason line and no art", async ({ page }) => {
  const s = JSON.parse(fixture("late-other"));
  s.launch.note = null;
  await open(page, JSON.stringify(s), LATE);
  await expect(slot(page, "launch-line")).toHaveText("running late by 4 h · Final checks 70/88");
  await expect(slot(page, "reason-line")).toBeHidden();
  await expect(slot(page, "busy-art")).toBeHidden();
});

test("late, status missing: running late · status offline, with no reason", async ({ page }) => {
  await open(page, null, LATE);
  await expect(slot(page, "launch-line")).toHaveText("running late · status offline");
  await expect(slot(page, "reason-line")).toBeHidden();
  await expect(slot(page, "busy-art")).toBeHidden();
});

// The needle's angle from its computed transform: -90° is "empty", +90° is "online!".
const needleDeg = (page) => p1(page).locator(".needle").evaluate((el) => {
  const m = new DOMMatrix(getComputedStyle(el).transform);
  return Math.round((Math.atan2(m.b, m.a) * 180) / Math.PI);
});

test("needle: rests at empty with no status, and follows final checks (41/88)", async ({ page }) => {
  await open(page, null);
  expect(await needleDeg(page)).toBe(-90);
  await page.unrouteAll();
  await serve(page, fixture("fresh"));
  await page.clock.fastForward(5 * 60e3); // jump to the next feed tick; runFor would step every timer on the page
  await expect.poll(() => needleDeg(page)).toBe(-6); // -90 + 180 × 41/88
});

for (const [name, suffix] of [["shipped-early", "shipped 2 h early"], ["shipped-late", "shipped 2 h late"]]) {
  test(`${name}: the ONLINE stamp replaces the countdown, needle at online!`, async ({ page }) => {
    await open(page, fixture(name), LATE);
    const stamp = slot(page, "stamp");
    await expect(stamp).toBeVisible();
    await expect(stamp).toContainText("ONLINE");
    await expect(slot(page, "stamp-suffix")).toHaveText(suffix);
    await expect(live(page).locator('[data-slot="stamp"]')).toHaveCount(1);
    await expect(p1(page).locator(".clock")).toBeHidden();
    await expect(slot(page, "launch-line")).toBeHidden();
    await expect.poll(() => needleDeg(page)).toBe(90);
  });
}

test("the countdown digits are not in a live region; the stamp is hidden before shipping", async ({ page }) => {
  await open(page, fixture("fresh"));
  await expect(slot(page, "days")).toHaveText("0");
  await expect(p1(page).locator('[aria-live] [data-slot="days"]')).toHaveCount(0);
  await expect(slot(page, "stamp")).toBeHidden();
});

// Story 41 (CLS < 0.1): after the deadline a load renders late-unknown first (no status yet), then
// late + reason + busy art when the status lands. Nothing below the launch block may move.
async function statusArrivesLate(page) {
  await page.route(STATUS, async (route) => {
    await new Promise((r) => setTimeout(r, 500));
    await route.fulfill({ status: 200, body: fixture("late-busy"), headers: { "access-control-allow-origin": "*" } })
      .catch(() => {}); // the page may already be gone
  });
  await page.clock.install({ time: LATE.getTime() - 1000 });
  await page.clock.pauseAt(LATE);
  await page.goto("/");
  await expect(slot(page, "launch-line")).toHaveText("running late · status offline");
  const below = page.locator("#p2");
  const before = await below.boundingBox();
  await expect(slot(page, "busy-art")).toBeVisible();
  await expect(slot(page, "reason-line")).toBeVisible();
  expect((await below.boundingBox()).y).toBe(before.y);
}

test("after the deadline, the status arriving late does not move the page below the hero", ({ page }) =>
  statusArrivesLate(page));

test.describe("tablet width (601–960 px)", () => {
  test.use({ viewport: { width: 820, height: 1000 } });
  test("after the deadline, the status arriving late does not move the page below the hero", ({ page }) =>
    statusArrivesLate(page));
});

test("shipped: the ONLINE stamp keeps the hero look, not p. 5's", async ({ page }) => {
  await open(page, fixture("shipped-early"), LATE);
  const stamp = slot(page, "stamp");
  await expect(stamp).toBeVisible();
  await expect(stamp).toHaveCSS("font-size", "44px");
  await expect(stamp).toHaveCSS("border-top-style", "double");
  await expect(stamp).not.toHaveCSS("min-height", "120px"); // p. 5's stamp cell
  const deg = await stamp.evaluate((el) => {
    const m = new DOMMatrix(getComputedStyle(el).transform);
    return Math.round((Math.atan2(m.b, m.a) * 180) / Math.PI);
  });
  expect(deg).toBe(-4);
});
