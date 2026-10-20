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

// The label's drawn text (not its 44px tap box) is what must stay clear and near its plate.
const IDS = ["ears", "transcriber", "notes", "memory", "hands"];
const luminance = (rgb) => {
  const [r, g, b] = rgb.match(/\d+/g).slice(0, 3).map((v) => v / 255).map((v) => (v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4));
  return .2126 * r + .7152 * g + .0722 * b;
};
const overlap = (a, b) => !(a.right <= b.left || b.right <= a.left || a.bottom <= b.top || b.bottom <= a.top);

// Everything in screen pixels: label text boxes, each plate's seat centre (read from the art itself), the ring
// box, and the pulled-out plate's box (its outline from plate-pop.svg, turned by the pop's own rotation).
const geometry = (page) => page.evaluate(async () => {
  const points = (d) => [...d.matchAll(/(-?[\d.]+),(-?[\d.]+)/g)].map((m) => [+m[1], +m[2]]);
  const box = (pts) => ({ left: Math.min(...pts.map((p) => p[0])), right: Math.max(...pts.map((p) => p[0])),
    top: Math.min(...pts.map((p) => p[1])), bottom: Math.max(...pts.map((p) => p[1])) });
  const get = async (name) => (await (await fetch(`assets/art/${name}`)).text());
  const art = document.querySelector("#p4 .plates"), at = art.getBoundingClientRect(), k = at.width / 760;
  const px = ([x, y]) => [at.left + x * k, at.top + y * k];
  // Plates in file order: ears, transcriber, notes, hands, memory. Only hands sits in a translated group.
  const order = ["ears", "transcriber", "notes", "hands", "memory"];
  const seats = {};
  [...(await get("a-plates-bare.svg")).matchAll(/(?:<g transform="translate\(([-\d.]+) ([-\d.]+)\)">)?<path d="([^"]+)"[^>]*stroke-width="2.6"/g)]
    .forEach(([, dx = 0, dy = 0, d], i) => {
      const b = box(points(d).map(([x, y]) => [x + +dx, y + +dy]));
      seats[order[i]] = px([(b.left + b.right) / 2, (b.top + b.bottom) / 2]);
    });
  const pop = document.querySelector("#p4 .plates > .pop");
  const m = new DOMMatrix(getComputedStyle(pop).transform), a = Math.atan2(m.b, m.a);
  const outline = points([...(await get("plate-pop.svg")).matchAll(/<path d="([^"]+)"[^>]*stroke-width="2.6"/g)][0][1])
    .map(([x, y]) => px([360 + (x - 360) * Math.cos(a) - (y - 360) * Math.sin(a), 360 + (x - 360) * Math.sin(a) + (y - 360) * Math.cos(a)]));
  const labels = {};
  for (const b of art.querySelectorAll('[data-slot="plate"]')) {
    const r = document.createRange(); r.selectNodeContents(b);
    const t = r.getBoundingClientRect();
    labels[b.value] = { left: t.left, right: t.right, top: t.top, bottom: t.bottom, color: getComputedStyle(b).color };
  }
  const ring = art.querySelector('[data-slot="ring"]').getBoundingClientRect();
  const h = document.querySelector("#p4 .hint").getBoundingClientRect();
  return { labels, seats, hint: { left: h.left, right: h.right, top: h.top, bottom: h.bottom }, pop: box(outline), ring: { left: ring.left, right: ring.right, top: ring.top, bottom: ring.bottom },
    bg: getComputedStyle(art.closest(".sheet")).backgroundColor };
});

for (const width of [1440, 1280, 1180, 1101, 1024, 390]) {
  test(`at ${width}, every open plate: each label is nearest its own plate, clear of the ring, the pulled-out plate and the hint, and reads at 3:1`, async ({ page }) => {
    test.skip(page.viewportSize().width !== 1440, "desktop project sets the width");
    await page.setViewportSize({ width, height: 900 });
    for (const open of IDS) {
      await page.locator(`#p4 [data-slot="plate"][value="${open}"]`).click();
      await page.waitForTimeout(350); // the label's colour transition settles
      const g = await geometry(page);
      const where = (id) => `${open} open, ${id}`;
      for (const id of IDS) {
        const l = g.labels[id], c = [(l.left + l.right) / 2, (l.top + l.bottom) / 2];
        const dist = (key) => Math.hypot(c[0] - g.seats[key][0], c[1] - g.seats[key][1]);
        const nearest = IDS.reduce((best, key) => (dist(key) < dist(best) ? key : best));
        expect(nearest, `${where(id)}: nearest plate is ${nearest}`).toBe(id);
        expect(overlap(l, g.ring), `${where(id)} meets the ring ${JSON.stringify({ l, ring: g.ring })}`).toBe(false);
        expect(overlap(l, g.pop), `${where(id)} meets the pulled-out plate ${JSON.stringify({ l, pop: g.pop })}`).toBe(false);
        expect(overlap(l, g.hint), `${where(id)} meets the hint ${JSON.stringify({ l, hint: g.hint })}`).toBe(false);
      }
      const fg = luminance(g.labels[open].color), bg = luminance(g.bg);
      expect((Math.max(fg, bg) + .05) / (Math.min(fg, bg) + .05), `${open} open: label contrast`).toBeGreaterThanOrEqual(3);
    }
  });
}

// The red rule is drawn by the first row's top edge, so it follows the header however many lines the tagline takes.
test("at every width the red rule sits below the card's header and no tagline leaves one word alone on its last line", async ({ page }) => {
  test.skip(page.viewportSize().width !== 1440, "desktop project sets the width");
  for (const width of [1920, 1440, 1280, 1180, 1024, 768, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    for (const id of ["ears", "transcriber", "notes", "memory", "hands"]) {
      await page.locator(`#p4 [data-slot="other-plate"][value="${id}"]`).click();
      const m = await page.locator("#p4 fieldset").evaluate((f) => {
        const card = f.closest(".index-card"), tilt = card.style.transform;
        card.style.transform = "none"; // the card's 1deg tilt would stagger the words of one line
        const shown = [...f.querySelectorAll(".tagline span")].find((x) => getComputedStyle(x).display !== "none");
        const node = shown.firstChild, text = node.data;
        const tops = [];
        for (const w of text.matchAll(/\S+/g)) {
          const r = document.createRange(); r.setStart(node, w.index); r.setEnd(node, w.index + w[0].length);
          tops.push(Math.round(r.getBoundingClientRect().top));
        }
        const last = tops.filter((t) => t === tops.at(-1)).length;
        card.style.transform = tilt;
        // Layout offsets, not bounding boxes: the card is tilted 1deg, which skews boxes by several px.
        const bottom = (el) => el.offsetTop + el.offsetHeight;
        const first = f.querySelector(".option");
        return { lines: new Set(tops).size, last, headBottom: Math.max(bottom(f.querySelector("legend")), bottom(f.querySelector(".tagline"))), ruleTop: first.offsetTop, rule: getComputedStyle(first).borderTopWidth };
      });
      expect(m.rule, `${id} at ${width}px: rule`).toBe("2px");
      expect(m.ruleTop, `${id} at ${width}px: rule below header`).toBeGreaterThanOrEqual(m.headBottom - .5);
      if (m.lines > 1) expect(m.last, `${id} at ${width}px: words on the last line`).toBeGreaterThanOrEqual(2);
    }
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

// Words of a text node by line, with the card's 1deg tilt off (it staggers the words of one line).
const lineStats = `(el) => {
  const node = [...el.childNodes].filter((n) => n.nodeType === 3 && n.data.trim()).at(-1);
  const tops = [];
  for (const w of node.data.matchAll(/\\S+/g)) {
    const r = document.createRange(); r.setStart(node, w.index); r.setEnd(node, w.index + w[0].length);
    tops.push(Math.round(r.getBoundingClientRect().top));
  }
  return { lines: new Set(tops).size, last: tops.filter((t) => t === tops.at(-1)).length };
}`;

test("the card is wide enough to read, and no option or sub-line leaves one word alone, from 1440 down to 1024", async ({ page }) => {
  test.skip(page.viewportSize().width !== 1440, "desktop project sets the width");
  for (const width of [1440, 1280, 1180, 1101, 1024]) {
    await page.setViewportSize({ width, height: 900 });
    const cardWidth = await page.locator("#p4 .index-card").evaluate((c) => c.offsetWidth);
    expect(cardWidth, `card width at ${width}px`).toBeGreaterThanOrEqual(400);
    for (const id of ["ears", "transcriber", "notes", "memory", "hands"]) {
      await page.locator(`#p4 [data-slot="other-plate"][value="${id}"]`).click();
      const rows = await page.locator("#p4 fieldset").evaluate((f, stats) => {
        const card = f.closest(".index-card"), tilt = card.style.transform;
        card.style.transform = "none";
        const measure = eval(stats);
        const out = [...f.querySelectorAll(".option label, .option .note")].map((el) => ({ text: el.textContent, ...measure(el) }));
        card.style.transform = tilt;
        return out;
      }, lineStats);
      for (const r of rows) if (r.lines > 1) expect(r.last, `${id} at ${width}px: "${r.text}"`).toBeGreaterThanOrEqual(2);
    }
  }
});

test("the 'other plates' icons stay on one row at every width", async ({ page }) => {
  test.skip(page.viewportSize().width !== 1440, "desktop project sets the width");
  for (const width of [1440, 1280, 1180, 1024, 768, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    const tops = await page.locator("#p4 .other-plates li").evaluateAll((all) => all.map((li) => Math.round(li.offsetTop)));
    expect(new Set(tops).size, `${width}px: ${tops}`).toBe(1);
  }
});

// D4's card is as tall as its rows, and the row of other plates stays put: the card hugs its content, and
// the space the tallest card would need is reserved under it, as plain paper, not as empty ruled lines.
test("the card hugs its rows, and the 'other plates' row holds its place for every plate", async ({ page }) => {
  const card = page.locator("#p4 .index-card"), others = page.locator("#p4 .others");
  const slack = () => card.evaluate((c) => {
    const f = c.querySelector("fieldset"), last = f.lastElementChild, offline = c.querySelector(".offline");
    return { blank: offline.offsetTop - (last.offsetTop + last.offsetHeight), below: c.offsetHeight - (offline.offsetTop + offline.offsetHeight) };
  });
  const y = async () => Math.round((await others.boundingBox()).y + await page.evaluate(() => scrollY));
  await page.locator('#p4 [data-slot="other-plate"][value="ears"]').click();
  const earsHeight = await card.evaluate((c) => c.offsetHeight), start = await y();
  for (const id of ["hands", "ears", "transcriber", "memory", "notes"]) {
    await page.locator(`#p4 [data-slot="other-plate"][value="${id}"]`).click();
    const s = await slack();
    expect(s.blank, `${id}: blank ruled space between the last row and the status line`).toBeLessThanOrEqual(60);
    expect(s.below, `${id}: space under the status line`).toBeLessThanOrEqual(48);
    expect(await y(), `${id}: the other-plates row`).toBe(start);
  }
  await page.locator('#p4 [data-slot="other-plate"][value="hands"]').click();
  expect(await card.evaluate((c) => c.offsetHeight)).toBeLessThan(earsHeight - 100);
});

test("opening a plate pulls that plate's drawing out: the pop-out art turns to the chosen plate", async ({ page }) => {
  const pop = page.locator("#p4 .plates > .pop");
  await expect(pop).toBeVisible(); // hands is open on load
  const turn = () => pop.evaluate((p) => new DOMMatrix(getComputedStyle(p).transform).toString());
  const hands = await turn();
  await page.locator('#p4 [data-slot="plate"][value="transcriber"]').click();
  expect(await turn()).not.toBe(hands);
});

// The reserve is two lines (site.css .offline min-height 2.4em); this is what bounds it.
test("the longest status line wraps to two lines at most, from 320 to 1920", async ({ page }) => {
  test.skip(page.viewportSize().width !== 1440, "desktop project sets the width");
  for (const width of [320, 390, 768, 1024, 1440, 1920]) {
    await page.setViewportSize({ width, height: 900 });
    const line = page.locator('#p4 [data-slot="offline-line"]');
    await expect(line).toHaveText("notes and commands still need the internet");
    const lines = await line.evaluate((el) => {
      const range = document.createRange(); range.selectNodeContents(el);
      return new Set([...range.getClientRects()].filter((r) => r.width > 0).map((r) => Math.round(r.top))).size;
    });
    expect(lines, `${width}px`).toBeLessThanOrEqual(2);
  }
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
