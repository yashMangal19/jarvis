import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

const T0 = Date.parse("2026-10-19T10:00:00Z");

// The page fetches status.json from GitHub; serve the fresh fixture so this smoke never hits the network.
test.beforeEach(async ({ page }) => {
  const body = readFileSync(new URL("../test/fixtures/status/fresh.json", import.meta.url), "utf8");
  await page.route("https://raw.githubusercontent.com/**", (route) =>
    route.fulfill({ status: 200, body, headers: { "access-control-allow-origin": "*" } }));
  // Paused after load, so only runFor moves time and each step lands on its exact millisecond.
  await page.clock.install({ time: T0 });
  await page.goto("/");
  await page.clock.pauseAt(T0 + 5e3);
});

const p5 = (page) => page.locator("#p5");
const slip = (page, id) => p5(page).locator(`[data-slot=slip][value=${id}]`);
const say = async (page, id) => {
  await slip(page, id).click();
  await page.clock.runFor(1500); // mic 400 → wave 500 → transcript 600, then the card
};

test("priya, then yes, stamps SENT ✓", async ({ page }) => {
  await say(page, "priya");
  await p5(page).getByRole("button", { name: "yes" }).click();
  await expect(p5(page).locator("[data-slot=stamp]")).toHaveText("SENT ✓");
});

test("reminder, then yes, says DONE ✓ and reminder set for 7 pm", async ({ page }) => {
  await say(page, "reminder");
  await p5(page).getByRole("button", { name: "yes" }).click();
  await expect(p5(page).locator("[data-slot=stamp]")).toHaveText("DONE ✓");
  await expect(p5(page).locator("[aria-live=polite]").getByText("reminder set for 7 pm")).toBeVisible();
});

test("reminder, then no, cancels and stamps nothing", async ({ page }) => {
  await say(page, "reminder");
  await p5(page).getByRole("button", { name: "no" }).click();
  await expect(p5(page).locator("[aria-live=polite]").getByText("cancelled. nothing left your mac.")).toBeVisible();
  await expect(p5(page).locator("[data-slot=stamp]")).toBeHidden();
});

test("the pricing question answers with its source and no yes/no", async ({ page }) => {
  await say(page, "pricing");
  await expect(p5(page).getByText("you settled on ₹499 a month, starting november.")).toBeVisible();
  await expect(p5(page).getByText("from tuesday's 3 pm note")).toBeVisible();
  await expect(p5(page).getByRole("button", { name: /^(yes|no)$/ })).toHaveCount(0);
});

test("the steps arrive in order: mic, wave, transcript, then the card", async ({ page }) => {
  await slip(page, "priya").click();
  const shown = (name) => p5(page).locator(`[data-slot=${name}]`);
  await page.clock.runFor(399);
  await expect(shown("mic")).toBeHidden();
  await page.clock.runFor(1);
  await expect(shown("mic")).toBeVisible();
  await expect(shown("wave")).toBeHidden();
  await page.clock.runFor(500);
  await expect(shown("wave")).toBeVisible();
  await expect(shown("transcript")).toBeHidden();
  await page.clock.runFor(600);
  await expect(shown("transcript")).toHaveText("“send priya: running 10 min late”");
  await expect(shown("read-back")).toBeVisible();
});

test("picking another slip mid-run starts over, and the old run never lands", async ({ page }) => {
  await say(page, "priya");
  await p5(page).getByRole("button", { name: "yes" }).click();
  await slip(page, "pricing").click();
  await expect(p5(page).locator("[data-slot=stamp]")).toBeHidden();
  await expect(p5(page).locator("[data-slot=read-back]")).toBeHidden();
  await page.clock.runFor(1000);
  await slip(page, "reminder").click(); // abandons pricing before its card
  await page.clock.runFor(1500);
  await expect(p5(page).locator("[data-slot=answer]")).toBeHidden();
  await expect(p5(page).locator("[data-slot=read-back-text]")).toContainText("call mom at 7 pm");
  await expect(slip(page, "reminder")).toHaveAttribute("aria-pressed", "true");
  await expect(slip(page, "pricing")).toHaveAttribute("aria-pressed", "false");
});

test("under reduced motion every step shows without waiting", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await slip(page, "priya").click();
  await page.clock.runFor(0);
  for (const name of ["mic", "wave", "transcript", "read-back"]) {
    await expect(p5(page).locator(`[data-slot=${name}]`)).toBeVisible();
  }
});

test("shown yes/no have names, and the result lives in a polite region", async ({ page }) => {
  await say(page, "priya");
  for (const name of ["yes", "no"]) {
    await expect(p5(page).locator(`[data-slot=${name}]`)).toHaveAccessibleName(name);
  }
  await expect(p5(page).locator("[aria-live=polite] [data-slot=stamp]")).toHaveCount(1);
});
