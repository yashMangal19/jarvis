import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

// Serve the fresh status fixture and abort the CDN, so this smoke never hits the network.
test.beforeEach(async ({ page }) => {
  const body = readFileSync(new URL("../test/fixtures/status/fresh.json", import.meta.url), "utf8");
  await page.route("https://raw.githubusercontent.com/**", (route) =>
    route.fulfill({ status: 200, body, headers: { "access-control-allow-origin": "*" } }));
  await page.route("https://cdnjs.cloudflare.com/**", (route) => route.abort());
});

// Same bytes cdnjs serves for gsap 3.15.0 (checked at pin time), so the page's SRI hashes must match them.
async function serveGsap(page) {
  await page.unroute("https://cdnjs.cloudflare.com/**");
  await page.route("https://cdnjs.cloudflare.com/ajax/libs/gsap/3.15.0/*.js", (route) => {
    const file = new URL(route.request().url()).pathname.split("/").pop();
    route.fulfill({
      status: 200, body: readFileSync(new URL(`../node_modules/gsap/dist/${file}`, import.meta.url)),
      headers: { "content-type": "application/javascript", "access-control-allow-origin": "*" },
    });
  });
}

const turned = (page) => page.locator("#p2 .cards li.is-turned");

test("scrolling p. 2 past turns every card of the flip-book", async ({ page }) => {
  await serveGsap(page);
  await page.goto("/");
  await expect(turned(page)).toHaveCount(0);
  await page.locator("#p3").scrollIntoViewIfNeeded();
  await page.mouse.wheel(0, 2000);
  await expect(turned(page)).toHaveCount(6);
});

test("p. 4's plates fly in, land on their spots and still pop out on click", async ({ page }) => {
  await serveGsap(page);
  await page.goto("/");
  const ears = page.locator('#p4 [data-slot="plate"][value="ears"]');
  await ears.evaluate((b) => new MutationObserver(() => {
    if (b.style.opacity !== "") b.dataset.flew = "yes";
  }).observe(b, { attributeFilter: ["style"] }));
  await page.locator("#p4").scrollIntoViewIfNeeded();
  await expect(ears).toHaveAttribute("data-flew", "yes");
  await expect.poll(() => ears.evaluate((b) => [b.style.opacity, b.style.transform, b.style.getPropertyValue("--x")]))
    .toEqual(["", "", "47%"]);
  await ears.click();
  await expect(ears).toHaveAttribute("aria-expanded", "true");
});

test("under reduced motion the page never asks the CDN for anything", async ({ page }) => {
  const asked = [];
  page.on("request", (r) => { if (r.url().startsWith("https://cdnjs.cloudflare.com/")) asked.push(r.url()); });
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/", { waitUntil: "load" });
  await page.locator("#p4").scrollIntoViewIfNeeded();
  await expect(soon(page)).toBeVisible(); // the page's modules have run
  expect(asked).toEqual([]);
});

const soon = (page) => page.locator('#p2 [data-slot="player"]').getByText("promo lands soon");

test("with no promo yet, the player says promo lands soon", async ({ page }) => {
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
