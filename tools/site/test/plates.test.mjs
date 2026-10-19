import { test } from "node:test";
import assert from "node:assert/strict";
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
  const own = "your own — bring your own model or tool";
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
