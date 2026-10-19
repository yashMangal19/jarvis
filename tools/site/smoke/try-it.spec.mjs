import { test, expect } from "./test.mjs";
import { readFileSync } from "node:fs";

const T0 = Date.parse("2026-10-19T10:00:00Z");

const fixture = (name) => readFileSync(new URL(`../test/fixtures/status/${name}.json`, import.meta.url), "utf8");
const serve = (page, name) => page.route("https://raw.githubusercontent.com/**", (route) =>
  route.fulfill({ status: 200, body: fixture(name), headers: { "access-control-allow-origin": "*" } }));
// The stamp's tilt in degrees, read from its computed transform.
const tilt = (locator) => locator.evaluate((el) => {
  const m = new DOMMatrix(getComputedStyle(el).transform);
  return Math.round(Math.atan2(m.b, m.a) * 180 / Math.PI);
});

// try-it.css loads after hero.css, so its stamp rules must stay on p. 5.
test("p. 1's ONLINE stamp keeps hero.css's double border and -4deg tilt", async ({ page }) => {
  const late = Date.parse("2026-10-20T01:30:00+05:30");
  await serve(page, "shipped-early");
  await page.clock.install({ time: late - 1000 });
  await page.clock.pauseAt(late);
  await page.goto("/");
  const stamp = page.locator("#p1 [data-slot=stamp]");
  await expect(stamp).toBeVisible();
  await expect(stamp).toHaveCSS("border-top-style", "double");
  expect(await tilt(stamp)).toBe(-4);
  await expect(stamp).toHaveCSS("animation-name", "none");
});

test.describe("p. 5 demo", () => {
// The page fetches status.json from GitHub; serve the fresh fixture so this smoke never hits the network.
test.beforeEach(async ({ page }) => {
  await serve(page, "fresh");
  // Paused before the page loads (as the p. 1 test above does), so only runFor moves time and each step lands on its
  // exact millisecond. Pausing after goto raced the real clock: a slow load passed the pause time and it threw.
  await page.clock.install({ time: T0 - 1000 });
  await page.clock.pauseAt(T0);
  await page.goto("/");
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

test("the p. 5 stamp shows, tilted 6deg", async ({ page }) => {
  await say(page, "priya");
  await p5(page).getByRole("button", { name: "yes" }).click();
  await expect(p5(page).locator("[data-slot=stamp]")).toBeVisible();
  expect(await tilt(p5(page).locator("[data-slot=stamp]"))).toBe(6);
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

// V-2: the page opens filled, like D5/M5, not on a run's worth of blank reserved paper.
test("before any pick, the last slip is followed by content within 120px", async ({ page }) => {
  const gap = await p5(page).evaluate((sec) => {
    const slipsBottom = sec.querySelector(".slips").getBoundingClientRect().bottom;
    const tops = [...sec.querySelectorAll(".step, .transcript, .read-back, .promise")]
      .filter((el) => el.checkVisibility({ visibilityProperty: true }))
      .map((el) => el.getBoundingClientRect().top).filter((t) => t >= slipsBottom);
    return Math.min(...tops) - slipsBottom;
  });
  expect(gap).toBeLessThan(120);
});

// V-2's other half: steps not shown yet keep their size, so a run never collapses or jumps the page.
test("from the opening state through a run to yes, nothing below the demo moves", async ({ page }) => {
  const promise = p5(page).locator(".promise");
  // Relative to p. 5's top, so a page above it changing height cannot move the number.
  const at = () => promise.evaluate((el) => Math.round(el.getBoundingClientRect().top - el.closest("#p5").getBoundingClientRect().top));
  const opening = await at();
  await slip(page, "reminder").click();
  await page.clock.runFor(450); // mid-run: the mic is in, the rest is not
  expect(await at()).toBe(opening);
  await page.clock.runFor(1050);
  expect(await at()).toBe(opening);
  await p5(page).getByRole("button", { name: "yes" }).click();
  expect(await at()).toBe(opening);
});

// V-16: "reminder set for 7 pm" stays on one line; it once broke as "7 / pm" at 390.
test("the result line after yes is one line", async ({ page }) => {
  await say(page, "reminder");
  await p5(page).getByRole("button", { name: "yes" }).click();
  const lines = await p5(page).locator("[data-slot=result-line]").evaluate((el) =>
    Math.round(el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight)));
  expect(lines).toBe(1);
});

// V-15: D5 draws arrows mic → wave → card and captions the card. M5 drops them, like the step captions.
test("during a run the flow arrows and the card caption show on desktop", async ({ page }, info) => {
  test.skip(info.project.name === "phone", "M5 draws no flow arrows or step captions");
  await say(page, "priya");
  // Two arrows are visible: mic → wave, and the one inside the shown card. The other card's is hidden with it.
  await expect(p5(page).locator(".arrow:visible")).toHaveCount(2);
  await expect(p5(page).getByText("3. reads it back. you say yes.")).toBeVisible();
});

// F-2: the answer card shares the read-back's reserved cell but is not stretched to fill it.
test("the pricing answer card is its own height, shorter than the shared card cell", async ({ page }) => {
  await say(page, "pricing");
  const [card, cell] = await p5(page).locator("[data-slot=answer]").evaluate((el) => [
    el.offsetHeight, parseFloat(getComputedStyle(el.parentElement).gridTemplateRows)]); // offsetHeight: untilted
  expect(card).toBeLessThan(cell - 40); // stretched it equals the cell; its own height is ~88px less at 1440 and 390
});

test("the picked slip is marked '← this one', outside its accessible name", async ({ page }) => {
  await slip(page, "reminder").click();
  const mark = (id) => slip(page, id).evaluate((b) => getComputedStyle(b.parentElement, "::after").content);
  expect(await mark("reminder")).toContain("this one");
  expect(await mark("priya")).toBe("none");
  await expect(slip(page, "reminder")).toHaveAccessibleName("“remind me to call mom at 7”");
});

// N-12: the marker takes no layout of its own, so moving it to another slip moves no slip.
test("picking a slip moves no slip", async ({ page }) => {
  const tops = () => p5(page).locator("[data-slot=slip]").evaluateAll((bs) =>
    bs.map((b) => Math.round(b.getBoundingClientRect().top - b.closest("#p5").getBoundingClientRect().top)));
  const opening = await tops();
  await slip(page, "reminder").click();
  expect(await tops()).toEqual(opening);
});

// N-11: the opening state has no blank band between the read-back card and the promise line.
test("in the opening state the promise line sits within 80px of the read-back card", async ({ page }, info) => {
  test.skip(info.project.name === "desktop", "D5 puts the caption and the stamp's cell between card and promise");
  const gap = await p5(page).evaluate((sec) =>
    sec.querySelector(".promise").getBoundingClientRect().top - sec.querySelector("[data-slot=read-back]").getBoundingClientRect().bottom);
  expect(gap).toBeLessThan(80);
});

// N-13 / F-3: the wave → card arrow's real tip (its transform-origin, which the turn leaves fixed) lands within 12px of
// the card's bottom-left corner, as D5 draws it, for the read-back and the shorter answer card, at three desktop widths.
for (const [id, card, run] of [["priya", "read-back", say], ["pricing", "answer", say]]) {
  for (const width of [1024, 1440, 1920]) {
    test(`the arrow to the ${card} card ends within 12px of it at ${width}`, async ({ page }, info) => {
      test.skip(info.project.name === "phone", "M5 draws no flow arrows");
      await page.setViewportSize({ width, height: 900 });
      await run(page, id);
      const miss = await p5(page).evaluate((sec, slot) => {
        const c = sec.querySelector(`[data-slot=${slot}]`);
        const arrow = c.querySelector(".to-card");
        // The arrow is the card's child, so the card's 1deg tilt moves tip and corner together. Measure both untilted
        // (a tilted card's bounding box has a corner that is not the card's corner). The arrow's own turn is about its
        // tip (the transform-origin), so the tip is the unturned box's origin point.
        const saved = [c.style.transform, arrow.style.rotate];
        c.style.transform = "none"; arrow.style.rotate = "none";
        const r = arrow.getBoundingClientRect(), [ox, oy] = getComputedStyle(arrow).transformOrigin.split(" ").map(parseFloat);
        const b = c.getBoundingClientRect();
        [c.style.transform, arrow.style.rotate] = saved;
        return Math.hypot(r.left + ox - b.left, r.top + oy - b.bottom);
      }, card === "answer" ? "answer" : "read-back");
      expect(miss).toBeLessThan(12);
    });
  }
}

// F-1: after yes the stamp never meets the result line, at any phone width. They are rows, not overlapping boxes.
for (const width of [320, 360, 375, 390]) {
  test(`after yes the stamp does not touch the result line at ${width}`, async ({ page }, info) => {
    test.skip(info.project.name === "desktop", "the stamp is pinned to the card only on phones");
    await page.setViewportSize({ width, height: 844 });
    await say(page, "reminder");
    await p5(page).getByRole("button", { name: "yes" }).click();
    const [stamp, line] = await p5(page).evaluate((sec) =>
      ["[data-slot=stamp]", "[data-slot=result-line]"].map((q) => { const r = sec.querySelector(q).getBoundingClientRect(); return { top: r.top, bottom: r.bottom }; }));
    expect(stamp.bottom).toBeLessThanOrEqual(line.top);
  });
}
});
