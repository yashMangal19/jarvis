import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";
import { NOW } from "../test/fixtures/clock.mjs";

const STATUS = "https://raw.githubusercontent.com/yashMangal19/jarvis/status/status.json?*";
const fixture = (name) =>
  readFileSync(new URL(`../test/fixtures/status/${name}.json`, import.meta.url), "utf8");
const ago = (minutes) => new Date(NOW.getTime() - minutes * 60e3).toISOString();

// fresh.json carries two commits; the page shows five.
const freshFive = () => {
  const s = JSON.parse(fixture("fresh"));
  s.commits = [18, 3 * 60, 5 * 60, 26 * 60, 2 * 24 * 60]
    .map((m, i) => ({ sha: `c0ffee${i}`, message: `commit ${i + 1}`, at: ago(m) }));
  return JSON.stringify(s);
};

// Serves each body in turn (the last one repeats); null means a 404. Returns the hit counter.
async function serve(page, ...bodies) {
  const hits = { n: 0 };
  await page.route(STATUS, (route) => {
    const body = bodies[Math.min(hits.n++, bodies.length - 1)];
    return route.fulfill(body === null
      ? { status: 404, body: "404: Not Found" }
      : { status: 200, body, headers: { "access-control-allow-origin": "*" } });
  });
  return hits;
}

const p3 = (page) => page.locator("#p3");
const slot = (page, name) => p3(page).locator(`[data-slot="${name}"]`);
const NUMBERS = ["waves-done", "tests-green", "hand-checks-pass", "hand-checks-total", "commit-age"];

async function open(page, time = NOW) {
  await page.clock.install({ time });
  await page.goto("/");
}

test("fresh: N of 10 done, the counts, and five commit rows with their age", async ({ page }) => {
  await serve(page, freshFive());
  await open(page);
  await expect(p3(page).locator(".done")).toHaveText("8 of 10 done.");
  await expect(p3(page).locator('[data-slot="wave-boxes"] img[src$="box-tick.svg"]')).toHaveCount(8);
  await expect(slot(page, "tests-green")).toHaveText("287");
  await expect(slot(page, "hand-checks-pass")).toHaveText("41");
  await expect(slot(page, "commit-age")).toHaveText(["18m ago", "3h ago", "5h ago", "26h ago", "2d ago"]);
  await expect(slot(page, "commit-msg")).toHaveText(["commit 1", "commit 2", "commit 3", "commit 4", "commit 5"]);
  await expect(slot(page, "updates-line")).toHaveText("updates itself every hour");
  await expect(slot(page, "stale-note")).toBeHidden();
});

test("stale: the red 'last update N h ago' note shows", async ({ page }) => {
  await serve(page, fixture("stale"));
  await open(page);
  await expect(slot(page, "stale-note")).toBeVisible();
  await expect(slot(page, "stale-note")).toHaveText("last update 3 h ago");
});

for (const [what, body] of [["missing (404)", null], ["invalid file", fixture("malformed")]]) {
  test(`${what}: status offline, and no digits in the live-build numbers`, async ({ page }) => {
    await serve(page, body);
    await open(page);
    await expect(slot(page, "updates-line")).toHaveText("status offline");
    for (const name of NUMBERS) {
      for (const text of await slot(page, name).allTextContents()) expect(text).not.toMatch(/\d/);
    }
    await expect(p3(page).locator('[data-slot="wave-boxes"] img[src$="box-tick.svg"]')).toHaveCount(0);
  });
}

test("shipped: final numbers line, and no stale note however old", async ({ page }) => {
  await serve(page, fixture("shipped-early"));
  await open(page, new Date("2026-10-20T12:00:00+05:30"));
  await expect(slot(page, "updates-line")).toHaveText("final numbers · shipped 19 oct");
  await expect(slot(page, "stale-note")).toBeHidden();
  await expect(slot(page, "hand-checks-pass")).toHaveText("88");
});

test("every 5 minutes it refetches; a failed later tick keeps the last good numbers", async ({ page }) => {
  const hits = await serve(page, fixture("stale"), freshFive(), null);
  await open(page);
  await expect(slot(page, "tests-green")).toHaveText("198");

  await page.clock.runFor(5 * 60e3);
  await expect(slot(page, "tests-green")).toHaveText("287");

  await page.clock.runFor(5 * 60e3);
  await expect.poll(() => hits.n).toBe(3);
  await expect(slot(page, "tests-green")).toHaveText("287");
  await expect(slot(page, "updates-line")).toHaveText("updates itself every hour");
});

test("a fetch that never answers times out to status offline, and the next tick still runs", async ({ page }) => {
  const hits = { n: 0 };
  await page.route(STATUS, (route) => {
    if (hits.n++ === 0) return; // never answered
    return route.fulfill({ status: 200, body: fixture("stale"), headers: { "access-control-allow-origin": "*" } });
  });
  await open(page);
  await expect.poll(() => hits.n).toBe(1);
  await page.clock.runFor(20e3);
  await expect(slot(page, "updates-line")).toHaveText("status offline");

  await page.clock.runFor(5 * 60e3 - 20e3 + 1e3); // just past the 5-minute tick, short of its own timeout
  await expect.poll(() => hits.n).toBe(2);
  await expect(slot(page, "tests-green")).toHaveText("198");
});
