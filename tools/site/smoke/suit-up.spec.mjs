import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

// The page fetches status.json from GitHub; serve the fresh fixture so this smoke never hits the network.
test.beforeEach(async ({ page }) => {
  const body = readFileSync(new URL("../test/fixtures/status/fresh.json", import.meta.url), "utf8");
  await page.route("https://raw.githubusercontent.com/**", (route) =>
    route.fulfill({ status: 200, body, headers: { "access-control-allow-origin": "*" } }));
  await page.goto("/");
});

const line = (page) => page.locator('#p4 [data-slot="offline-line"]');

test("on load the status line says notes and commands need the internet", async ({ page }) => {
  await expect(line(page)).toHaveText("notes and commands still need the internet");
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
