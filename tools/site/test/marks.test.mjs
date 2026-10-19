import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { marksFromForks } from "../../../docs/js/logic/marks.js";

const fixture = (name) =>
  JSON.parse(readFileSync(new URL(`./fixtures/forks/${name}.json`, import.meta.url), "utf8"));
const labels = (forks) => marksFromForks(forks).map((m) => m.label);

test("two forks: two marks in API order, then mark 3 for you", () => {
  assert.deepEqual(labels(fixture("two")), [
    "mark 1 · @fork-owner-1",
    "mark 2 · @fork-owner-2",
    "mark 3 · @you?",
  ]);
});

test("no forks: only mark 1 for you", () => {
  assert.deepEqual(labels(fixture("none")), ["mark 1 · @you?"]);
});

test("seven forks: the oldest five, then mark 8 for you (the mark your fork would get)", () => {
  assert.deepEqual(labels(fixture("seven")), [
    "mark 1 · @fork-owner-1",
    "mark 2 · @fork-owner-2",
    "mark 3 · @fork-owner-3",
    "mark 4 · @fork-owner-4",
    "mark 5 · @fork-owner-5",
    "mark 8 · @you?",
  ]);
});

for (const [name, failed] of [["null", null], ["an error object", { message: "API rate limit exceeded" }]]) {
  test(`API failure (${name}): only mark 1 for you`, () => {
    assert.deepEqual(labels(failed), ["mark 1 · @you?"]);
  });
}

test("never more than 6 cards, and @you? is always last", () => {
  for (const name of ["none", "two", "seven"]) {
    const out = labels(fixture(name));
    assert.ok(out.length <= 6, name);
    assert.match(out.at(-1), /@you\?$/, name);
    assert.equal(out.filter((l) => l.endsWith("@you?")).length, 1, name);
  }
});
