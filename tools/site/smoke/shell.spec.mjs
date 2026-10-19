import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

// The page fetches status.json from GitHub; serve the fresh fixture so this smoke never hits the network.
test.beforeEach(async ({ page }) => {
  const body = readFileSync(new URL("../test/fixtures/status/fresh.json", import.meta.url), "utf8");
  await page.route("https://raw.githubusercontent.com/**", (route) =>
    route.fulfill({ status: 200, body, headers: { "access-control-allow-origin": "*" } }));
});

test("p. 1–3 show their fixed copy", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { level: 1, name: "Build your own suit." })).toBeVisible();
  for (const text of ["mon 19 oct, 9 pm IST", "the 45-second version", "no sound", "final hand checks", "/88"]) {
    await expect(page.getByText(text, { exact: false }).first()).toBeVisible();
  }
});

test("no horizontal scroll at 390", async ({ page }) => {
  test.skip(page.viewportSize().width !== 390, "phone only");
  await page.goto("/");
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});

for (const width of [1280, 1024, 768]) {
  test(`nothing on p. 1–3 is cut off at ${width}`, async ({ page }) => {
    test.skip(page.viewportSize().width !== 1440, "desktop project sets the width");
    await page.setViewportSize({ width, height: 900 });
    await page.goto("/");
    const cut = await page.evaluate((w) =>
      [...document.querySelectorAll("#p1 *, #p2 *, #p3 *, header *")]
        .filter((el) => el.checkVisibility() && el.getBoundingClientRect().width > 0)
        .filter((el) => el.getBoundingClientRect().right > w + 1)
        .map((el) => `${el.tagName.toLowerCase()}.${el.className} right=${Math.round(el.getBoundingClientRect().right)}`), width);
    expect(cut).toEqual([]);
  });
}
