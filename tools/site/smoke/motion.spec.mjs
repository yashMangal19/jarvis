import { test, expect } from "./test.mjs";
import { readFileSync } from "node:fs";

// Serve the fresh status fixture so this smoke never hits the network (the shared test owns the CDN).
test.beforeEach(async ({ page }) => {
  const body = readFileSync(new URL("../test/fixtures/status/fresh.json", import.meta.url), "utf8");
  await page.route("https://raw.githubusercontent.com/**", (route) =>
    route.fulfill({ status: 200, body, headers: { "access-control-allow-origin": "*" } }));
});

const soon = (page) => page.locator('#p2 [data-slot="player"]').getByRole("img", { name: "promo lands soon" });
// docs/media/ now holds the real promo, so "no promo yet" is a 404 the test serves itself.
const noPromo = (page) => page.route("**/media/promo.mp4", (route) => route.fulfill({ status: 404 }));

test("by default a spec never reaches the CDN: the GSAP request fails locally", async ({ page }) => {
  const failed = [];
  page.on("requestfailed", (r) => failed.push(r.url()));
  await page.goto("/");
  await expect.poll(() => failed.some((u) => u.startsWith("https://cdnjs.cloudflare.com/"))).toBe(true);
});

test.describe("with GSAP served from the pinned local copy", () => {
  test.use({ gsap: true });

  test("scrolling p. 2 past turns every card of the flip-book", async ({ page }) => {
    const turned = page.locator("#p2 .cards li.is-turned");
    await page.goto("/");
    await expect(turned).toHaveCount(0);
    await page.locator("#p3").scrollIntoViewIfNeeded();
    await page.mouse.wheel(0, 2000);
    await expect(turned).toHaveCount(6);
  });

  test("p. 4's plates fly in from nearby, land on their spots and still pop out on click", async ({ page }) => {
    await page.goto("/");
    const plates = page.locator('#p4 [data-slot="plate"]');
    // Record the furthest any plate is ever displaced while it flies.
    await plates.evaluateAll((all) => {
      window.flyMax = 0;
      for (const b of all) {
        new MutationObserver(() => {
          const m = new DOMMatrix(getComputedStyle(b).transform);
          if (b.style.opacity !== "") window.flyMax = Math.max(window.flyMax, Math.abs(m.e), Math.abs(m.f));
        }).observe(b, { attributeFilter: ["style"] });
      }
    });
    await page.locator("#p4").scrollIntoViewIfNeeded();
    await expect.poll(() => page.evaluate(() => window.flyMax)).toBeGreaterThan(0);
    const ears = plates.and(page.locator('[value="ears"]'));
    await expect.poll(() => ears.evaluate((b) => [b.style.opacity, b.style.transform, b.style.getPropertyValue("--x")]))
      .toEqual(["", "", "47%"]);
    expect(await page.evaluate(() => window.flyMax)).toBeLessThan(400);
    await ears.click();
    await expect(ears).toHaveAttribute("aria-expanded", "true");
  });
});

test("under reduced motion the page never asks the CDN for anything", async ({ page }) => {
  const asked = [];
  page.on("request", (r) => { if (r.url().startsWith("https://cdnjs.cloudflare.com/")) asked.push(r.url()); });
  await noPromo(page);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/", { waitUntil: "load" });
  await page.locator("#p4").scrollIntoViewIfNeeded();
  await expect(soon(page)).toBeVisible(); // the page's modules have run
  expect(asked).toEqual([]);
});

test("with no promo yet, the player shows the promo lands soon card", async ({ page }) => {
  await noPromo(page);
  await page.goto("/");
  await expect(soon(page)).toBeVisible();
});

test("once the promo is there, it loads its metadata and promo lands soon goes away", async ({ page }) => {
  const mp4 = readFileSync(new URL("fixtures/tiny.mp4", import.meta.url));
  await page.route("**/media/promo.mp4", (route) =>
    route.fulfill({ status: 200, body: mp4, headers: { "content-type": "video/mp4" } }));
  await page.goto("/");
  await expect.poll(() => page.locator("#p2 video").evaluate((v) => v.readyState)).toBeGreaterThanOrEqual(1);
  await expect(soon(page)).toBeHidden();
});
