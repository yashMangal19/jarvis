import { test, expect } from "./fixture.mjs";
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

// Later routes win over beforeEach's, so this swaps the status feed to "v0.1.0 has shipped".
const shipped = (page) => page.route("https://raw.githubusercontent.com/**", (route) =>
  route.fulfill({ status: 200, body: fixture("status/shipped-early.json"), headers: CORS }));
const BREW = "brew install yashMangal19/tap/jarvis";
const brewStrip = (page) => page.locator("#p8 .strip").filter({ hasText: BREW });

const marks = (page) => page.locator('#p7 ol[data-slot="marks"] > li.mark');

// The mark icon's drawing covers only part of its 160-unit box. Its paths are absolute M/L points,
// so the ink's width is their x range: drawn width = the img's width × INK.
const art = readFileSync(new URL("../../../docs/assets/art/flip-2.svg", import.meta.url), "utf8");
const xs = [...art.matchAll(/[ML](-?[\d.]+),/g)].map((m) => Number(m[1]));
const INK = (Math.max(...xs) - Math.min(...xs)) / 160;
const json = (body) => ({ status: 200, body, headers: { ...CORS, "content-type": "application/json" } });

test("two forks → mark 1 and 2 by owner, then mark 3 @you?", async ({ page }) => {
  const forks = fixture("forks/two.json");
  await page.route("https://api.github.com/**", (route) =>
    route.fulfill({ status: 200, body: forks, headers: { ...CORS, "content-type": "application/json" } }));
  await page.goto("/");
  await expect(marks(page)).toHaveText(["mark 1 @fork-owner-1", "mark 2 @fork-owner-2", "mark 3 @you?"]);
});

test("every mark card: the icon is drawn about 65px wide, the handle on its own line under the name", async ({ page }) => {
  const forks = fixture("forks/two.json");
  await page.route("https://api.github.com/**", (route) =>
    route.fulfill({ status: 200, body: forks, headers: { ...CORS, "content-type": "application/json" } }));
  await page.goto("/");
  await expect(marks(page)).toHaveCount(3);
  for (const [name, handle] of [["mark 1", "@fork-owner-1"], ["mark 3", "@you?"]]) {
    const card = marks(page).filter({ hasText: handle });
    const drawn = (await card.locator("img").boundingBox()).width * INK;
    expect(drawn).toBeGreaterThanOrEqual(60);
    expect(drawn).toBeLessThanOrEqual(70);
    await expect(card.getByText(handle, { exact: true })).toBeVisible();
    const n = await card.getByText(name, { exact: true }).boundingBox();
    const h = await card.getByText(handle, { exact: true }).boundingBox();
    expect(h.y).toBeGreaterThanOrEqual(n.y + n.height - 1);
  }
});

test("the mark cards are separate index cards: a gap between each and the next", async ({ page }) => {
  await page.route("https://api.github.com/**", (route) => route.fulfill(json(fixture("forks/two.json"))));
  await page.goto("/");
  await expect(marks(page)).toHaveCount(3);
  // layout boxes, before the tilt: offsetTop is relative to the shared list
  const boxes = await marks(page).evaluateAll((lis) => lis.map((li) => [li.offsetLeft, li.offsetTop, li.offsetWidth, li.offsetHeight]));
  for (let i = 1; i < boxes.length; i++) {
    const [ax, ay, aw, ah] = boxes[i - 1], [bx, by] = boxes[i];
    const sameRow = bx >= ax + aw; // the next card starts right of this one (the phone's two columns)
    const gap = sameRow ? bx - (ax + aw) : by - (ay + ah);
    expect(gap, `gap before card ${i + 1}`).toBeGreaterThanOrEqual(8);
  }
});

test("the icon's drawing keeps at least 6px from the handle (phone, where nothing is tilted)", async ({ page }) => {
  test.skip(page.viewportSize().width !== 390, "phone only");
  await page.route("https://api.github.com/**", (route) => route.fulfill(json(fixture("forks/two.json"))));
  await page.goto("/");
  await expect(marks(page)).toHaveCount(3);
  const INK_RIGHT = Math.max(...xs) / 160; // where the drawing ends, as a share of the img width
  const gaps = await marks(page).evaluateAll((lis, inkRight) => lis.map((li) => {
    const img = li.querySelector("img").getBoundingClientRect();
    const text = li.querySelector(".handle").firstChild;
    const r = document.createRange();
    r.setStart(text, 0); r.setEnd(text, 1);
    return r.getBoundingClientRect().left - (img.left + img.width * inkRight);
  }), INK_RIGHT);
  for (const gap of gaps) expect(gap).toBeGreaterThanOrEqual(6);
});

test("no capsule caption leaves a single word alone on its last line", async ({ page }) => {
  await page.goto("/");
  const lines = await page.$$eval("#p7 .capsule p", (ps) => ps.map((p) => {
    const text = p.firstChild, r = document.createRange(), tops = [];
    for (const m of text.data.matchAll(/\S+/g)) {
      r.setStart(text, m.index); r.setEnd(text, m.index + m[0].length);
      tops.push(Math.round(r.getBoundingClientRect().top));
    }
    return { text: text.data, lines: new Set(tops).size, onLast: tops.filter((t) => t === tops.at(-1)).length };
  }));
  for (const { text, lines: n, onLast } of lines) expect(n === 1 || onLast >= 2, `"${text}" ends alone`).toBe(true);
});

test("the cards tilt alternately, as in D7", async ({ page }) => {
  test.skip(page.viewportSize().width !== 1440, "the phone grid sets them straight");
  await page.route("https://api.github.com/**", (route) => route.fulfill(json(fixture("forks/two.json"))));
  await page.goto("/");
  await expect(marks(page)).toHaveCount(3);
  // sign of the rotation: matrix(a, b, ...) has b = sin(angle)
  const signs = await marks(page).evaluateAll((lis) => lis.map((li) => Math.sign(new DOMMatrix(getComputedStyle(li).transform).b)));
  expect(signs).toEqual([-1, 1, -1]);
});

test("a card cached in an older shape (label only) never renders blank", async ({ page }) => {
  await page.addInitScript(() => sessionStorage.setItem("jarvis.marks",
    JSON.stringify({ at: Date.now(), marks: [{ label: "mark 1 · @old-shape" }] })));
  await page.route("https://api.github.com/**", (route) => route.fulfill(json(fixture("forks/two.json"))));
  await page.goto("/");
  await expect(marks(page)).toHaveText(["mark 1 @fork-owner-1", "mark 2 @fork-owner-2", "mark 3 @you?"]);
});

test("a stacked card's tape never covers the handle of the card above it", async ({ page }) => {
  await page.route("https://api.github.com/**", (route) => route.fulfill(json(fixture("forks/two.json"))));
  await page.goto("/");
  await expect(marks(page)).toHaveCount(3);
  for (const i of [0, 1]) {
    const h = await marks(page).nth(i).locator(".handle").boundingBox();
    const t = await marks(page).nth(i + 1).locator(".t1").boundingBox();
    const overlap = h.x < t.x + t.width && t.x < h.x + h.width && h.y < t.y + t.height && t.y < h.y + h.height;
    expect(overlap, `card ${i + 2}'s tape over card ${i + 1}'s handle`).toBe(false);
  }
});

test("a short handle like @fork-owner-1 stays on one line, phone included", async ({ page }) => {
  await page.route("https://api.github.com/**", (route) => route.fulfill(json(fixture("forks/two.json"))));
  await page.goto("/");
  const handle = marks(page).first().getByText("@fork-owner-1", { exact: true });
  await expect(handle).toBeVisible();
  const [height, line] = await handle.evaluate((el) => [el.getBoundingClientRect().height, parseFloat(getComputedStyle(el).lineHeight)]);
  expect(height).toBeLessThan(line * 1.5);
});

for (const [why, answer, cached] of [
  ["403 (rate limit)", (r) => r.fulfill({ status: 403, body: "{}", headers: CORS }), true],
  ["429 (rate limit)", (r) => r.fulfill({ status: 429, body: "{}", headers: CORS }), true],
  ["500", (r) => r.fulfill({ status: 500, body: "{}", headers: CORS }), false],
  ["network error", (r) => r.abort(), false],
]) {
  test(`first answer ${why}: the next load ${cached ? "reuses it" : "asks again and gets the forks"}`, async ({ page }) => {
    let calls = 0;
    await page.route("https://api.github.com/**", (route) =>
      ++calls === 1 ? answer(route) : route.fulfill(json(fixture("forks/two.json"))));
    await page.goto("/");
    await expect.poll(() => calls).toBe(1);
    await expect(marks(page)).toHaveText(["mark 1 @you?"]);
    await page.reload();
    await expect(marks(page)).toHaveText(cached ? ["mark 1 @you?"] : ["mark 1 @fork-owner-1", "mark 2 @fork-owner-2", "mark 3 @you?"]);
    expect(calls).toBe(cached ? 1 : 2);
  });
}

test("a second page load in the same session makes no forks request", async ({ page }) => {
  const forks = fixture("forks/two.json");
  let calls = 0;
  await page.route("https://api.github.com/**", (route) => {
    calls++;
    return route.fulfill({ status: 200, body: forks, headers: { ...CORS, "content-type": "application/json" } });
  });
  await page.goto("/");
  await expect(marks(page)).toHaveCount(3);
  await page.reload();
  await expect(marks(page)).toHaveCount(3);
  expect(calls).toBe(1);
});

test("forks API 403 → only mark 1 @you?", async ({ page }) => {
  await page.route("https://api.github.com/**", (route) =>
    route.fulfill({ status: 403, body: '{"message":"API rate limit exceeded"}', headers: CORS }));
  const answered = page.waitForResponse((r) => r.url().startsWith("https://api.github.com/"));
  await page.goto("/");
  await answered;
  await expect(marks(page)).toHaveText(["mark 1 @you?"]);
});

test("the brew strip's copy button puts the line on the clipboard and says copied", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await shipped(page);
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
  await expect(marks(page).first()).toHaveText(`mark 1 @${max}`);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});

test("screen readers hear copied: the button's name is its text and it is a polite live region", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.goto("/");
  const button = page.locator('#p8 button[data-copy="git clone github.com/yashMangal19/jarvis"]');
  await expect(button).toHaveAttribute("aria-live", "polite");
  await expect(button).toHaveAccessibleDescription("git clone github.com/yashMangal19/jarvis");
  await button.click();
  await expect(button).toHaveAccessibleName("copied");
});

test("before ship the brew strip is hidden; git clone and the guide stay", async ({ page }) => {
  const answered = page.waitForResponse((r) => r.url().startsWith("https://raw.githubusercontent.com/"));
  await page.goto("/");
  await answered;
  await expect(brewStrip(page)).toBeHidden();
  await expect(page.getByText(BREW)).toBeHidden();
  await expect(page.getByText("git clone github.com/yashMangal19/jarvis")).toBeVisible();
  await expect(page.locator('#p8 a[href="guide.html"]')).toBeVisible();
});

test("once shipped the brew strip appears without moving anything above it, and copy works", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  let release;
  const held = new Promise((r) => { release = r; });
  await page.route("https://raw.githubusercontent.com/**", async (route) => {
    await held;
    await route.fulfill({ status: 200, body: fixture("status/shipped-early.json"), headers: CORS });
  });
  await page.goto("/");
  // Measured within p. 8: the feed also reflows earlier pages (the hero's shipped state), which is not this strip's doing.
  const titleInPage = () => page.evaluate(() =>
    document.getElementById("p8-title").getBoundingClientRect().top - document.getElementById("p8").getBoundingClientRect().top);
  await expect(brewStrip(page)).toBeHidden(); // no flash before the feed answers
  const before = await titleInPage();
  release();
  await expect(brewStrip(page)).toBeVisible();
  expect(await titleInPage()).toBe(before);
  await brewStrip(page).getByRole("button").click();
  await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toBe(BREW);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(page.viewportSize().width);
});
