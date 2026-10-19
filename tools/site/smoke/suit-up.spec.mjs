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
  await expect(page.locator("#p4 .tagline")).toHaveText(/^does things( for you)?\. always asks first\.$/, { useInnerText: true });
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
  const art = await page.locator("#p4 .plates > img:first-child").getAttribute("src");
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

// The label's drawn text (not its 44px tap box) must sit clear of the ring's box.
const textBox = (button) => button.evaluate((b) => {
  const range = document.createRange(); range.selectNodeContents(b);
  const r = range.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height };
});
const apart = (a, b) => a.x + a.width <= b.x || b.x + b.width <= a.x || a.y + a.height <= b.y || b.y + b.height <= a.y;
const luminance = (rgb) => {
  const [r, g, b] = rgb.match(/\d+/g).slice(0, 3).map((v) => v / 255).map((v) => (v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4));
  return .2126 * r + .7152 * g + .0722 * b;
};

for (const id of ["ears", "transcriber", "notes", "memory", "hands"]) {
  test(`open ${id}: its label sits outside the ring and reads at 3:1 or more on the blueprint`, async ({ page }) => {
    const label = page.locator(`#p4 [data-slot="plate"][value="${id}"]`);
    await label.click();
    await page.waitForTimeout(400); // the pop transition settles
    const ring = await page.locator('#p4 [data-slot="ring"]').boundingBox();
    const text = await textBox(label);
    expect(apart(text, ring), JSON.stringify({ text, ring })).toBe(true);
    const fg = luminance(await label.evaluate((b) => getComputedStyle(b).color));
    const bg = luminance(await page.locator("#p4 .sheet").evaluate((s) => getComputedStyle(s).backgroundColor));
    expect((Math.max(fg, bg) + .05) / (Math.min(fg, bg) + .05)).toBeGreaterThanOrEqual(3);
  });
}

test("every tagline fits on one line beside the plate name", async ({ page }) => {
  for (const id of ["ears", "transcriber", "notes", "memory", "hands"]) {
    await page.locator(`#p4 [data-slot="other-plate"][value="${id}"]`).click();
    const lines = await page.locator("#p4 .tagline").evaluate((t) => {
      const range = document.createRange(); range.selectNodeContents(t);
      return new Set([...range.getClientRects()].filter((r) => r.width > 0).map((r) => Math.round(r.top))).size;
    });
    expect(lines, id).toBe(1);
  }
});

test("p. 1 and p. 4 draw the plates from one asset, and p. 1 keeps its ring on the notes plate", async ({ page }) => {
  const p1 = await page.locator("#p1 .plates > img:first-child").getAttribute("src");
  const p4 = await page.locator("#p4 .plates > img:first-child").getAttribute("src");
  expect(p1).toBe(p4);
  // D1: exactly one ring, round the pulled-out notes plate (bottom-left), with its label beside it.
  const ring = page.locator('#p1 [data-slot="ring"]');
  await expect(ring).toHaveCount(1);
  await expect(ring).toBeVisible();
  await expect(page.locator("#p1 .plates > .pop")).toBeVisible();
  const box = await page.locator("#p1 .plates").boundingBox();
  const r = await ring.boundingBox();
  const cx = (r.x + r.width / 2 - box.x) / box.width, cy = (r.y + r.height / 2 - box.y) / box.height;
  expect(cx).toBeLessThan(0.4);
  expect(cy).toBeGreaterThan(0.6);
  const notes = await page.locator("#p1 .plates .label", { hasText: "notes" }).boundingBox();
  expect(Math.abs(notes.y + notes.height / 2 - (r.y + r.height / 2))).toBeLessThan(r.height);
});

test("nothing below the card moves while you switch plates and tick engines", async ({ page }) => {
  const others = page.locator("#p4 .others");
  const y = async () => Math.round((await others.boundingBox()).y + await page.evaluate(() => scrollY));
  const start = await y();
  const open = (id) => page.locator(`#p4 [data-slot="other-plate"][value="${id}"]`).click();
  for (const id of ["ears", "transcriber", "notes", "memory", "hands"]) { await open(id); expect(await y(), id).toBe(start); }
  await open("notes"); await page.getByRole("radio", { name: "ollama" }).check();
  expect(await y(), "notes on ollama").toBe(start);
  await open("hands"); await page.getByRole("radio", { name: /your own/ }).check();
  expect(await y(), "fully offline").toBe(start);
});

test("the card reserves exactly what the ears card needs, so the hands card's blank is only the rows it lacks", async ({ page }) => {
  const content = () => page.locator("#p4 fieldset").evaluate((f) =>
    f.lastElementChild.getBoundingClientRect().bottom - f.getBoundingClientRect().top);
  const height = () => page.locator("#p4 fieldset").evaluate((f) => f.getBoundingClientRect().height);
  await page.locator('#p4 [data-slot="other-plate"][value="ears"]').click();
  const ears = await height();
  expect(ears).toBeLessThanOrEqual(await content() + 16);
  await page.locator('#p4 [data-slot="other-plate"][value="hands"]').click();
  expect(Math.abs(await height() - ears)).toBeLessThanOrEqual(1);
});

test("opening a plate pulls that plate's drawing out: the pop-out art turns to the chosen plate", async ({ page }) => {
  const pop = page.locator("#p4 .plates > .pop");
  await expect(pop).toBeVisible(); // hands is open on load
  const turn = () => pop.evaluate((p) => new DOMMatrix(getComputedStyle(p).transform).toString());
  const hands = await turn();
  await page.locator('#p4 [data-slot="plate"][value="transcriber"]').click();
  expect(await turn()).not.toBe(hands);
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
