import { test, expect } from "./test.mjs";
import { readFileSync } from "node:fs";

// The page fetches status.json from GitHub; serve the fresh fixture so this smoke never hits the network.
test.beforeEach(async ({ page }) => {
  const body = readFileSync(new URL("../test/fixtures/status/fresh.json", import.meta.url), "utf8");
  await page.route("https://raw.githubusercontent.com/**", (route) =>
    route.fulfill({ status: 200, body, headers: { "access-control-allow-origin": "*" } }));
  await page.goto("/");
});

const line = (page) => page.locator('#p4 [data-slot="offline-line"]');

test("on load the card is filled: hands is open on claude, and the line says notes and commands need the internet", async ({ page }) => {
  await expect(page.locator('#p4 [data-slot="plate"][value="hands"]')).toHaveAttribute("aria-expanded", "true");
  await expect(page.getByRole("group", { name: "hands" })).toBeVisible();
  await expect(page.getByRole("radio", { name: "claude" })).toBeChecked();
  await expect(page.getByRole("radio", { name: "claude" })).toHaveAccessibleDescription("smartest. needs the internet.");
  await expect(page.locator("#p4 .tagline")).toHaveText("does things for you. always asks first.");
  await expect(line(page)).toHaveText("notes and commands still need the internet");
  await expect(page.locator("#p4 :focus")).toHaveCount(0); // filling the card on load never steals focus
});

test("popping transcriber shows one red ring, on the plate drawing, not the label", async ({ page }) => {
  const transcriber = page.locator('#p4 [data-slot="plate"][value="transcriber"]');
  await transcriber.click();
  const ring = page.locator('#p4 [data-slot="ring"]');
  await expect(ring).toHaveCount(1);
  await expect(ring).toBeVisible();
  // The art itself carries no red: the baked-in ring would be a second one.
  const art = await page.locator("#p4 .plates > img:not(.ring)").getAttribute("src");
  expect(await (await page.request.get(art)).text()).not.toMatch(/#C8302A/i);
  await expect(transcriber).toHaveCSS("border-top-style", "none");
  // The transcriber plate is drawn right of centre, in the upper half of the art.
  const box = await page.locator("#p4 .plates").boundingBox();
  const r = await ring.boundingBox();
  const cx = (r.x + r.width / 2 - box.x) / box.width, cy = (r.y + r.height / 2 - box.y) / box.height;
  expect(cx).toBeGreaterThan(0.6);
  expect(cy).toBeGreaterThan(0.25);
  expect(cy).toBeLessThan(0.55);
});

test("the hint never sits on the bottom tape", async ({ page }) => {
  const hint = await page.locator("#p4 .hint").boundingBox();
  const tape = await page.locator("#p4 .sheet .t3").boundingBox();
  const apart = hint.x + hint.width <= tape.x || tape.x + tape.width <= hint.x
    || hint.y + hint.height <= tape.y || tape.y + tape.height <= hint.y;
  expect(apart, JSON.stringify({ hint, tape })).toBe(true);
});

test.describe("on a touch screen", () => {
  test.use({ hasTouch: true });
  test("the hint says tap, not click", async ({ page }) => {
    await expect(page.locator("#p4 .hint")).toHaveText("tap a plate to pop it out", { useInnerText: true });
  });
});

test("with a mouse the hint says click", async ({ page }) => {
  await expect(page.locator("#p4 .hint")).toHaveText("click a plate to pop it out", { useInnerText: true });
});

test("open notes, tick ollama: only commands still need the internet", async ({ page }) => {
  const notes = page.locator('#p4 [data-slot="plate"][value="notes"]');
  await notes.click();
  await expect(notes).toHaveAttribute("aria-expanded", "true");
  await expect(page.getByRole("radio", { name: "claude" })).toBeFocused();
  await page.getByRole("radio", { name: "ollama" }).check();
  await expect(line(page)).toHaveText("commands still need the internet");
});

test("Esc closes the card and puts focus back on the plate", async ({ page }) => {
  const memory = page.locator('#p4 [data-slot="plate"][value="memory"]');
  await memory.click();
  await page.keyboard.press("Escape");
  await expect(memory).toHaveAttribute("aria-expanded", "false");
  await expect(memory).toBeFocused();
  await expect(page.getByRole("radio")).toHaveCount(0);
});

test("ticks hold across cards: notes on ollama, hands on your own by keyboard, runs fully offline", async ({ page }) => {
  await page.locator('#p4 [data-slot="plate"][value="notes"]').click();
  await page.getByRole("radio", { name: "ollama" }).check();

  const hands = page.locator('#p4 [data-slot="plate"][value="hands"]');
  await page.locator('#p4 [data-slot="plate"][value="memory"]').focus();
  await page.keyboard.press("Tab");
  await expect(hands).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(hands).toHaveAttribute("aria-expanded", "true");
  await expect(page.getByRole("radio", { name: "claude" })).toBeFocused();
  await page.keyboard.press("ArrowDown");
  await expect(page.getByRole("radio", { name: /your own/ })).toBeChecked();
  await expect(line(page)).toHaveText("now it runs fully offline");
});

test("the hands card has no ollama row", async ({ page }) => {
  await page.locator('#p4 [data-slot="plate"][value="hands"]').click();
  await expect(page.getByRole("radio")).toHaveCount(2);
  await expect(page.getByRole("radio", { name: "ollama" })).toHaveCount(0);
});

test("a mini-icon switches to the memory card", async ({ page }) => {
  await page.locator('#p4 [data-slot="plate"][value="notes"]').click();
  await page.locator('#p4 [data-slot="other-plate"][value="memory"]').click();
  await expect(page.locator('#p4 [data-slot="plate"][value="memory"]')).toHaveAttribute("aria-expanded", "true");
  await expect(page.locator('#p4 [data-slot="plate"][value="notes"]')).toHaveAttribute("aria-expanded", "false");
  await expect(page.getByRole("group", { name: "memory" })).toBeVisible();
  await expect(page.getByRole("radio", { name: "naturallanguage" })).toBeChecked();
});
