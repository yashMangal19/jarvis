import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

// The page fetches status.json from GitHub; serve the fresh fixture so this smoke never hits the network.
test.beforeEach(async ({ page }) => {
  const body = readFileSync(new URL("../test/fixtures/status/fresh.json", import.meta.url), "utf8");
  await page.route("https://raw.githubusercontent.com/**", (route) =>
    route.fulfill({ status: 200, body, headers: { "access-control-allow-origin": "*" } }));
});

const AREAS = "#p4, #p5, #p6, #p7, #p8, body > footer";

test("p. 4–8 and the footer show their fixed copy", async ({ page }) => {
  await page.goto("/");
  for (const text of [
    "nothing leaves without your yes.",
    "cloud? only if you plug one in.",
    "brew install yashMangal19/tap/jarvis",
    "git clone github.com/yashMangal19/jarvis",
    "not affiliated with marvel or disney.",
    "mark 1 · @you?",
  ]) {
    await expect(page.getByText(text, { exact: false }).first()).toBeVisible();
  }
  await expect(page.locator('a[href="guide.html"]:visible').first()).toBeVisible();
});

test("every plate is a button reached by Tab, and every control on p. 4–8 has a name", async ({ page }) => {
  await page.goto("/");
  const plates = page.locator('#p4 button[aria-controls="plate-card"]');
  await expect(plates).toHaveCount(5);

  await page.locator("#p3 a").last().focus();
  const reached = [];
  for (let i = 0; i < 20 && reached.length < 5; i++) {
    await page.keyboard.press("Tab");
    const name = await page.evaluate(() => {
      const el = document.activeElement;
      return el?.matches('[aria-controls="plate-card"]') ? el.textContent.trim() : null;
    });
    if (name) reached.push(name);
  }
  expect(reached).toEqual(["ears", "transcriber", "notes", "memory", "hands"]);

  // Hidden slots (the read-back yes/no) leave the accessibility tree until a later ticket reveals them.
  const controls = page.locator(`:is(${AREAS}) :is(button, a):visible`);
  expect(await controls.count()).toBeGreaterThan(0);
  for (const control of await controls.all()) await expect(control).toHaveAccessibleName(/\S/);
});

test("no horizontal scroll at 390", async ({ page }) => {
  test.skip(page.viewportSize().width !== 390, "phone only");
  await page.goto("/");
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});

for (const width of [1280, 1024, 768, 390]) {
  test(`nothing on p. 4–8 or the footer is cut off at ${width}`, async ({ page }) => {
    test.skip(page.viewportSize().width !== 1440, "desktop project sets the width");
    await page.setViewportSize({ width, height: 900 });
    await page.goto("/");
    const cut = await page.evaluate(([w, areas]) =>
      [...document.querySelectorAll(areas.split(", ").map((a) => `${a}, ${a} *`).join(", "))]
        .filter((el) => el.checkVisibility() && el.getBoundingClientRect().width > 0)
        .filter((el) => el.getBoundingClientRect().right > w + 1 || el.getBoundingClientRect().left < -1)
        .map((el) => `${el.tagName.toLowerCase()}.${el.className} right=${Math.round(el.getBoundingClientRect().right)}`),
    [width, AREAS]);
    expect(cut).toEqual([]);
  });
}

// p. 4–8 heading styles must not leak onto earlier pages (p. 2's title is 64px at desktop and in-between widths).
for (const width of [1440, 800]) {
  test(`p. 2's title keeps its own size at ${width}`, async ({ page }) => {
    test.skip(page.viewportSize().width !== 1440, "desktop project sets the width");
    await page.setViewportSize({ width, height: 900 });
    await page.goto("/");
    const title = page.locator("#p2-title");
    await expect(title).toHaveCSS("font-size", "64px");
    await expect(title).toHaveCSS("margin-bottom", "28px");
  });
}
