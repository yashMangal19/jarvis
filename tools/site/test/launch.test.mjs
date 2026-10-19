import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { launchState, LABEL } from "../../../docs/js/logic/launch.js";
import { parseStatus } from "../../../docs/js/logic/status.js";
import { NOW } from "./fixtures/clock.mjs";

const fixture = (name) =>
  parseStatus(readFileSync(new URL(`./fixtures/status/${name}.json`, import.meta.url), "utf8"));

test("no status before the deadline counts down 9 h 0 min with the needle at empty", () => {
  assert.deepEqual(launchState(NOW, null), {
    state: "countdown", countdown: { days: 0, hours: 9, minutes: 0 }, needle: 0,
  });
});

const at = (iso) => new Date(iso);
const AFTER = at("2026-10-19T21:30:00+05:30");

test("no status after the deadline is late-unknown with no reason line", () => {
  assert.deepEqual(launchState(AFTER, null), {
    state: "late-unknown", line: "running late · status offline", needle: 0,
  });
});

const shippedAt = (iso) => {
  const s = fixture("shipped-early");
  s.release.shipped_at = iso;
  return s;
};

test("shipped 5 h before the deadline is online, shipped 5 h early, needle full", () => {
  assert.deepEqual(launchState(NOW, shippedAt("2026-10-19T16:00:00+05:30")), {
    state: "online", suffix: "shipped 5 h early", needle: 1,
  });
});

const suffix = (now, s) => launchState(now, s).suffix;

test("shipped 30 min early has no suffix", () => {
  assert.equal(suffix(NOW, shippedAt("2026-10-19T20:30:00+05:30")), null);
});

test("shipped 40 min after the deadline (0 h late) has no suffix", () => {
  assert.equal(suffix(AFTER, shippedAt("2026-10-19T21:40:00+05:30")), null);
});

test("shipped 2 h 30 min after the deadline says shipped 2 h late", () => {
  const late = at("2026-10-20T00:00:00+05:30");
  assert.deepEqual(launchState(late, fixture("shipped-late")), {
    state: "online", suffix: "shipped 2 h late", needle: 1,
  });
});

test("unshipped before the deadline counts down with the needle at final checks passed", () => {
  assert.deepEqual(launchState(NOW, fixture("fresh")), {
    state: "countdown", countdown: { days: 0, hours: 9, minutes: 0 }, needle: 41 / 88,
  });
});

const LATE_40_MIN = at("2026-10-19T21:40:00+05:30");

test("unshipped 40 min past the deadline with no failures is late for final checks", () => {
  assert.deepEqual(launchState(LATE_40_MIN, fixture("late-qa")), {
    state: "late",
    line: "running late by 40 min · Final checks 70/88",
    reason: "still checking every bolt by hand.",
    showBusyArt: false,
    needle: 70 / 88,
  });
});

test("late with a failed final check gives the bugs reason", () => {
  const r = launchState(LATE_40_MIN, fixture("late-bugs"));
  assert.equal(r.reason, "found loose screws. tightening them.");
  assert.equal(r.line, "running late by 40 min · Final checks 66/88");
  assert.equal(r.showBusyArt, false);
});

test("late with note_kind busy gives the busy reason and shows the busy art", () => {
  const r = launchState(LATE_40_MIN, fixture("late-busy"));
  assert.equal(r.reason, "yash got pulled away. jarvis waits for him.");
  assert.equal(r.showBusyArt, true);
});

test("late with note_kind other shows Yash's note verbatim", () => {
  const r = launchState(LATE_40_MIN, fixture("late-other"));
  assert.equal(r.reason, "waiting on notarisation");
  assert.equal(r.showBusyArt, false);
});

test("note_kind qa overrides a failed final check", () => {
  const s = fixture("late-bugs");
  s.launch.note_kind = "qa";
  assert.equal(launchState(LATE_40_MIN, s).reason, "still checking every bolt by hand.");
});

test("3 h 10 min past the deadline says running late by 3 h", () => {
  const r = launchState(at("2026-10-20T00:10:00+05:30"), fixture("late-qa"));
  assert.equal(r.line, "running late by 3 h · Final checks 70/88");
});

test("no final checks yet keeps the needle at empty, before and after the deadline", () => {
  const s = fixture("fresh");
  s.qa = { total: 0, pass: 0, fail: 0, blocked: 0 };
  assert.equal(launchState(NOW, s).needle, 0);
  assert.equal(launchState(LATE_40_MIN, s).needle, 0);
});

test("countdown digits match for the same instant in different time-zone offsets", () => {
  const instants = ["2026-10-17T08:23:00+05:30", "2026-10-17T02:53:00Z", "2026-10-16T19:53:00-07:00"];
  for (const iso of instants) {
    assert.deepEqual(launchState(at(iso), null).countdown, { days: 2, hours: 12, minutes: 37 }, iso);
  }
});

test("countdown counts the last partial minute down to zero, never below", () => {
  assert.deepEqual(launchState(at("2026-10-19T20:59:30+05:30"), null).countdown,
    { days: 0, hours: 0, minutes: 0 });
  assert.equal(launchState(at("2026-10-19T21:00:00+05:30"), null).state, "late-unknown");
});

test("the deadline label is fixed IST wording", () => {
  assert.equal(LABEL, "mon 19 oct, 9 pm IST");
});
