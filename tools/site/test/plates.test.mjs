import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PLATES, offlineLine, defaultTicks } from "../../../docs/js/logic/plates.js";

test("the load state says notes and commands still need the internet", () => {
  assert.equal(offlineLine(defaultTicks()), "notes and commands still need the internet");
});

const tick = (changes) => ({ ...defaultTicks(), ...changes });
const plate = (id) => PLATES.find((p) => p.id === id);

test("moving notes or hands offline names what is left, and both gives fully offline", () => {
  assert.equal(offlineLine(tick({ notes: "ollama" })), "commands still need the internet");
  assert.equal(offlineLine(tick({ hands: "own" })), "notes still need the internet");
  assert.equal(offlineLine(tick({ notes: "ollama", hands: "own" })), "now it runs fully offline");
});

test("changing ears, transcriber or memory never changes the line", () => {
  for (const id of ["ears", "transcriber", "memory"]) {
    for (const o of plate(id).options) {
      assert.equal(offlineLine(tick({ [id]: o.id })), "notes and commands still need the internet");
      assert.equal(offlineLine(tick({ [id]: o.id, notes: "ollama", hands: "own" })), "now it runs fully offline");
    }
  }
});

test("plates list exactly the spec's rows, in order, each ending with your own", () => {
  const labels = Object.fromEntries(PLATES.map((p) => [p.id, p.options.map((o) => o.label)]));
  const own = "your own";
  assert.deepEqual(labels, {
    ears: ["any mic or airpods", "built-in mic (meeting mode)", "call audio", "voice memos", own],
    transcriber: ["whisper.cpp", "apple speechanalyzer", own],
    notes: ["claude", "apple foundation models", "ollama", own],
    memory: ["naturallanguage", "apple contextual", "core ai", own],
    hands: ["claude", own],
  });
  const defaults = PLATES.map((p) => p.options.find((o) => o.id === p.defaultId).label);
  assert.deepEqual(defaults, ["any mic or airpods", "whisper.cpp", "claude", "naturallanguage", "claude"]);
});

test("only the two claude rows need the internet, and hands has no ollama", () => {
  const online = PLATES.flatMap((p) => p.options.filter((o) => o.needsInternet).map((o) => `${p.id}/${o.label}`));
  assert.deepEqual(online, ["notes/claude", "hands/claude"]);
  assert.ok(!plate("hands").options.some((o) => /ollama/i.test(o.label)));
});

test("unknown plate or option ids fall back to the plate's default", () => {
  assert.equal(offlineLine(tick({ notes: "nope", hands: "own", wings: "x" })), "notes still need the internet");
  assert.equal(offlineLine({}), "notes and commands still need the internet");
  assert.equal(offlineLine(undefined), "notes and commands still need the internet");
});

test("each card heads with a lowercase tagline; hands uses the design's line", () => {
  for (const p of PLATES) assert.match(p.tagline, /^[a-z][a-z ,.]+\.$/, p.id);
  assert.equal(plate("hands").tagline, "does things for you. always asks first.");
});

test("every option has a lowercase sub-line that is true about the internet", () => {
  const note = (p, o) => plate(p).options.find((x) => x.id === o).note;
  assert.equal(note("notes", "claude"), "smartest. needs the internet.");
  assert.equal(note("notes", "ollama"), "runs on your mac. offline.");
  assert.equal(note("hands", "own"), "bring your own model or tool.");
  for (const p of PLATES) {
    for (const o of p.options) {
      assert.match(o.note, /^[a-z][a-z .,()]+\.$/, `${p.id}/${o.id}`);
      assert.equal(o.note.includes("needs the internet"), o.needsInternet, `${p.id}/${o.id}`);
    }
  }
});

test("a short tagline, where a plate has one, is the phone line and is shorter", () => {
  assert.equal(plate("hands").shortTagline, "does things. always asks first.");
  for (const p of PLATES.filter((x) => x.shortTagline)) {
    assert.match(p.shortTagline, /^[a-z][a-z ,.]+\.$/, p.id);
    assert.ok(p.shortTagline.length < p.tagline.length, p.id);
  }
});

test("the plates art seats all five plates: every plate outline sits the same distance from the core", () => {
  const svg = readFileSync(new URL("../../../docs/assets/art/a-plates-bare.svg", import.meta.url), "utf8");
  // A plate outline is a closed hand-drawn path at stroke-width 2.6; its centre is placed by any <g translate>.
  const centres = [...svg.matchAll(/(?:<g transform="translate\(([-\d.]+) ([-\d.]+)\)">)?<path d="([^"]+)"[^>]*stroke-width="2.6"/g)]
    .map(([, dx = 0, dy = 0, d]) => {
      const pts = [...d.matchAll(/([-\d.]+),([-\d.]+)/g)].map((m) => [+m[1] + +dx, +m[2] + +dy]);
      const xs = pts.map((q) => q[0]), ys = pts.map((q) => q[1]);
      return Math.hypot((Math.min(...xs) + Math.max(...xs)) / 2 - 360, (Math.min(...ys) + Math.max(...ys)) / 2 - 360);
    });
  assert.equal(centres.length, 5);
  assert.ok(Math.max(...centres) - Math.min(...centres) < 15, `plate radii ${centres.map(Math.round)}`);
  assert.doesNotMatch(svg, /stroke-dasharray="6 6"|#C8302A/i, "no empty seat and no ring baked in");
});

test("the pulled-out plate art hard-codes no blueprint colour: the cover that hides the seated plate is a CSS mask", () => {
  const art = (name) => readFileSync(new URL(`../../../docs/assets/art/${name}`, import.meta.url), "utf8");
  assert.doesNotMatch(art("plate-pop.svg"), /#1F3F73|fill="#/i);
  assert.match(art("plate-cover.svg"), /<path/);
  assert.match(readFileSync(new URL("../../../docs/css/site.css", import.meta.url), "utf8"),
    /\.plates \.pop::before\s*{[^}]*var\(--blueprint\)/);
});
