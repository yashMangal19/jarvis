import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { parseStatus, freshness, liveLine, ageLabel } from "../../../docs/js/logic/status.js";
import { NOW } from "./fixtures/clock.mjs";

const fixture = (name) =>
  readFileSync(new URL(`./fixtures/status/${name}.json`, import.meta.url), "utf8");

test("a 3 h old unshipped status is stale and says so", () => {
  const f = freshness(parseStatus(fixture("stale")), NOW);
  assert.equal(f.stale, true);
  assert.equal(f.note, "last update 3 h ago");
});

test("unknown schema and malformed JSON are treated as missing", () => {
  assert.equal(parseStatus(fixture("unknown-schema")), null);
  assert.equal(parseStatus(fixture("malformed")), null);
});

for (const name of ["fresh", "stale", "shipped-early", "shipped-late",
  "late-qa", "late-bugs", "late-busy", "late-other"]) {
  test(`fixture ${name} parses`, () => {
    assert.equal(parseStatus(fixture(name))?.schema, 1);
  });
}

const broken = {
  "generated_at not a date": (s) => { s.generated_at = "yesterday"; },
  "qa missing": (s) => { delete s.qa; },
  "build.tests a string": (s) => { s.build.tests = "198"; },
  "qa.pass null": (s) => { s.qa.pass = null; },
  "commits not an array": (s) => { s.commits = {}; },
  "commit without sha": (s) => { delete s.commits[0].sha; },
  "commit date not a date": (s) => { s.commits[0].at = "soon"; },
  "release.shipped a string": (s) => { s.release.shipped = "false"; },
  "release.tag missing": (s) => { delete s.release.tag; },
  "shipped with no shipped_at": (s) => { s.release.shipped = true; },
  "launch.deadline not a date": (s) => { s.launch.deadline = 21; },
  "note_kind unknown": (s) => { s.launch.note_kind = "lunch"; },
  "note a number": (s) => { s.launch.note = 3; },
};
for (const [what, breakIt] of Object.entries(broken)) {
  test(`rejects a status whose ${what}`, () => {
    const s = JSON.parse(fixture("stale"));
    breakIt(s);
    assert.equal(parseStatus(s), null);
  });
}

const shippedStale = () => {
  const s = parseStatus(fixture("stale"));
  s.release.shipped = true;
  s.release.shipped_at = "2026-10-19T08:55:00+05:30";
  return s;
};

test("a recent status is not stale and has no note", () => {
  const f = freshness(parseStatus(fixture("fresh")), NOW);
  assert.equal(f.stale, false);
  assert.equal(f.note, null);
});

test("a shipped status is never stale, however old", () => {
  const f = freshness(shippedStale(), NOW);
  assert.equal(f.stale, false);
  assert.equal(f.note, null);
});

test("freshness accepts now as epoch ms", () => {
  assert.equal(freshness(parseStatus(fixture("stale")), NOW.getTime()).note, "last update 3 h ago");
});

test("live line: no status reads 'status offline'", () => {
  assert.equal(liveLine(null, NOW), "status offline");
});

test("live line: not shipped reads 'updates itself every hour'", () => {
  assert.equal(liveLine(parseStatus(fixture("stale")), NOW), "updates itself every hour");
});

test("live line: shipped reads the final numbers and the IST ship date", () => {
  assert.equal(liveLine(shippedStale(), NOW), "final numbers · shipped 19 oct");
});

test("live line: ship date is the IST calendar day, not UTC", () => {
  const s = shippedStale();
  s.release.shipped_at = "2026-10-19T20:00:00Z"; // 01:30 on 20 Oct in IST
  assert.equal(liveLine(s, NOW), "final numbers · shipped 20 oct");
});

test("commit age: minutes under an hour, hours under two days, then days", () => {
  const at = (minutesAgo) => new Date(NOW.getTime() - minutesAgo * 60e3).toISOString();
  assert.equal(ageLabel(at(18), NOW), "18m ago");
  assert.equal(ageLabel(at(59), NOW), "59m ago");
  assert.equal(ageLabel(at(60), NOW), "1h ago");
  assert.equal(ageLabel(at(47 * 60 + 59), NOW), "47h ago");
  assert.equal(ageLabel(at(48 * 60), NOW), "2d ago");
  assert.equal(ageLabel(at(9 * 24 * 60), NOW.getTime()), "9d ago");
});

test("commit age: a commit stamped after now (clock skew) reads 0m ago", () => {
  assert.equal(ageLabel(new Date(NOW.getTime() + 5 * 60e3).toISOString(), NOW), "0m ago");
});
