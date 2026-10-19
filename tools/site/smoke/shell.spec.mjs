import { test, expect } from "@playwright/test";

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
