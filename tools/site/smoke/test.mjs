// Every spec imports test from here, so none of them reaches cdnjs: the GSAP request is aborted
// (the page's no-motion fallback) unless a spec opts in with test.use({ gsap: true }). That serves
// the pinned devDependency, the same bytes cdnjs serves for 3.15.0, so the page's SRI hashes hold.
// Real GSAP's ticker under page.clock would otherwise step every animation frame.
import { test as base, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

export const test = base.extend({
  gsap: [false, { option: true }],
  cdn: [async ({ page, gsap }, use) => {
    await page.route("https://cdnjs.cloudflare.com/**", (route) => {
      if (!gsap) return route.abort();
      const file = new URL(route.request().url()).pathname.split("/").pop();
      return route.fulfill({
        status: 200, body: readFileSync(new URL(`../node_modules/gsap/dist/${file}`, import.meta.url)),
        headers: { "content-type": "application/javascript", "access-control-allow-origin": "*" },
      });
    });
    await use();
  }, { auto: true }],
});
export { expect };
