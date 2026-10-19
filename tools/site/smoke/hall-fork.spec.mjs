import { test, expect } from "./test.mjs";
import { readFileSync } from "node:fs";

const fixture = (path) => readFileSync(new URL(`../test/fixtures/${path}`, import.meta.url), "utf8");
const CORS = { "access-control-allow-origin": "*" };

// No network: status.json and the forks API are both routed to fixtures.
test.beforeEach(async ({ page }) => {
  const status = fixture("status/fresh.json");
  await page.route("https://raw.githubusercontent.com/**", (route) =>
    route.fulfill({ status: 200, body: status, headers: CORS }));
  const none = fixture("forks/none.json");
  await page.route("https://api.github.com/**", (route) =>
    route.fulfill({ status: 200, body: none, headers: { ...CORS, "content-type": "application/json" } }));
});

const marks = (page) => page.locator('#p7 ol[data-slot="marks"] > li.mark');

test("two forks → mark 1 and 2 by owner, then mark 3 · @you?", async ({ page }) => {
  const forks = fixture("forks/two.json");
  await page.route("https://api.github.com/**", (route) =>
    route.fulfill({ status: 200, body: forks, headers: { ...CORS, "content-type": "application/json" } }));
  await page.goto("/");
  await expect(marks(page)).toHaveText(["mark 1 · @fork-owner-1", "mark 2 · @fork-owner-2", "mark 3 · @you?"]);
});

test("forks API 403 → only mark 1 · @you?", async ({ page }) => {
  await page.route("https://api.github.com/**", (route) =>
    route.fulfill({ status: 403, body: '{"message":"API rate limit exceeded"}', headers: CORS }));
  const answered = page.waitForResponse((r) => r.url().startsWith("https://api.github.com/"));
  await page.goto("/");
  await answered;
  await expect(marks(page)).toHaveText(["mark 1 · @you?"]);
});

test("the brew strip's copy button puts the line on the clipboard and says copied", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.goto("/");
  const button = page.locator('#p8 button[data-copy="brew install yashMangal19/tap/jarvis"]');
  await button.click();
  await expect(button).toHaveText("copied");
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe("brew install yashMangal19/tap/jarvis");
  await expect(button).toHaveText("copy", { timeout: 4000 });
});

test("no clipboard API → the strip text is selected and the button never says copied", async ({ page }) => {
  await page.addInitScript(() => Object.defineProperty(Navigator.prototype, "clipboard", { get: () => undefined }));
  await page.goto("/");
  const button = page.locator('#p8 button[data-copy="git clone github.com/yashMangal19/jarvis"]');
  await button.click();
  expect(await page.evaluate(() => getSelection().toString())).toBe("git clone github.com/yashMangal19/jarvis");
  await expect(button).toHaveText("copy");
});

test("a 39-character login without hyphens fits at 390 with no horizontal scroll", async ({ page }) => {
  test.skip(page.viewportSize().width !== 390, "phone only");
  const max = "m".repeat(39); // GitHub's longest login, in the widest letter, with no hyphen to break at
  await page.route("https://api.github.com/**", (route) =>
    route.fulfill({ status: 200, json: [{ owner: { login: max } }], headers: CORS }));
  await page.goto("/");
  await expect(marks(page).first()).toHaveText(`mark 1 · @${max}`);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});

test("screen readers hear copied: the button's name is its text and it is a polite live region", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.goto("/");
  const button = page.locator('#p8 button[data-copy="brew install yashMangal19/tap/jarvis"]');
  await expect(button).toHaveAttribute("aria-live", "polite");
  await expect(button).toHaveAccessibleDescription("brew install yashMangal19/tap/jarvis");
  await button.click();
  await expect(button).toHaveAccessibleName("copied");
});
