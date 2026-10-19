import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { mkdtempSync, mkdirSync, rmSync, existsSync, readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { parseStatus } from "../../../docs/js/logic/status.js";
import { buildStatus } from "../status/compute.mjs";
import { collectGit } from "../status/collect-git.mjs";
import { NOW } from "./fixtures/clock.mjs";

const run = (name) => fileURLToPath(new URL(`./fixtures/runs/${name}/`, import.meta.url));
const NO_TAG = { commits: [], release: { tag: "v0.1.0", shipped: false, shipped_at: null } };

test("fresh build: nothing done, no gate yet, no results.yaml", () => {
  const s = buildStatus({ runDir: run("fresh"), notePath: run("fresh") + "launch-note.md", git: NO_TAG, now: NOW });
  assert.deepEqual(s.build, { waves_done: 0, waves_total: 2, tickets_done: 0, tickets_total: 3, tests: 0 });
  assert.deepEqual(s.qa, { total: 3, pass: 0, fail: 0, blocked: 0 });
  assert.deepEqual(s.launch, { deadline: "2026-10-19T21:00:00+05:30", note_kind: null, note: null });
  assert.equal(s.generated_at, NOW.toISOString());
  assert.notEqual(parseStatus(s), null);
});

const status = (name, note = "missing.md", git = NO_TAG) =>
  buildStatus({ runDir: run(name), notePath: run("notes") + note, git, now: NOW });

test("QA partial: a later wave can finish first, latest gate with a count wins", () => {
  const s = status("qa-partial");
  assert.deepEqual(s.build, { waves_done: 1, waves_total: 3, tickets_done: 2, tickets_total: 4, tests: 12 });
  assert.deepEqual(s.qa, { total: 5, pass: 2, fail: 0, blocked: 1 });
  assert.notEqual(parseStatus(s), null);
});

test("QA with a fail: the latest `at` per case wins, not the last line", () => {
  const s = status("qa-fail");
  assert.deepEqual(s.build, { waves_done: 2, waves_total: 2, tickets_done: 2, tickets_total: 2, tests: 40 });
  assert.deepEqual(s.qa, { total: 5, pass: 1, fail: 1, blocked: 0 });
  assert.notEqual(parseStatus(s), null);
});

test("QA counts only the spec-moment cases: ticket-moment cases and their results are left out", () => {
  const s = status("qa-moments");
  assert.deepEqual(s.qa, { total: 2, pass: 1, fail: 0, blocked: 1 });
  assert.notEqual(parseStatus(s), null);
});

const notes = {
  "busy.md": ["busy", null],
  "qa.md": ["qa", null],
  "bugs.md": ["bugs", null],
  "other.md": ["other", "waiting on notarisation"],
  "other-41.md": ["other", "the notary queue is slow tonight, sorry…"],
  "unknown.md": [null, null],
  "missing.md": [null, null],
};
for (const [file, [kind, text]] of Object.entries(notes)) {
  test(`launch note ${file} → ${kind} / ${text}`, () => {
    const s = status("qa-fail", file);
    assert.equal(s.launch.note_kind, kind);
    assert.equal(s.launch.note, text);
    assert.notEqual(parseStatus(s), null);
  });
}

test("bad JSON and a drifted run.json throw instead of guessing", () => {
  assert.throws(() => status("bad-json"), /run\.json/);
  assert.throws(() => status("drifted"), /run\.json: tickets\[\]/);
});

test("cases.yaml with no top-level cases: list, or no spec cases, throws instead of reporting 0", () => {
  assert.throws(() => status("qa-no-cases"), /cases\.yaml: no spec cases/);
  assert.throws(() => status("qa-only-ticket"), /cases\.yaml: no spec cases/);
});

// ── git collector and CLI, against a local repo in a temp dir (no network) ──

function makeOrigin() {
  const dir = mkdtempSync(join(tmpdir(), "status-job-"));
  const origin = join(dir, "origin");
  const env = { ...process.env, GIT_AUTHOR_NAME: "Demo", GIT_AUTHOR_EMAIL: "demo@example.invalid",
    GIT_COMMITTER_NAME: "Demo", GIT_COMMITTER_EMAIL: "demo@example.invalid", GIT_CONFIG_GLOBAL: "/dev/null" };
  const git = (...a) => execFileSync("git", ["-C", origin, "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", ...a],
    { env, encoding: "utf8" });
  const commit = (msg, date) => {
    env.GIT_AUTHOR_DATE = env.GIT_COMMITTER_DATE = date;
    git("commit", "--quiet", "--allow-empty", "-m", msg);
  };
  execFileSync("git", ["init", "--quiet", "-b", "main", origin], { env });
  commit("T-1: base", "2026-10-17T10:00:00+05:30");
  git("branch", "feature/jarvis-ambient-memory");
  commit("main: readme\n\nbody line not shown", "2026-10-17T12:00:00+05:30");
  git("checkout", "--quiet", "feature/jarvis-ambient-memory");
  commit("T-2: feature work", "2026-10-17T11:00:00+05:30");
  return { dir, origin, git, commit, cacheDir: join(dir, "cache", "repo.git") };
}

test("git collector: newest commits across both branches, shared one once; tag appears after fetch", () => {
  const o = makeOrigin();
  try {
    const before = collectGit({ cacheDir: o.cacheDir, remote: o.origin });
    assert.deepEqual(before.commits.map((c) => [c.message, c.at]), [
      ["main: readme", "2026-10-17T12:00:00+05:30"],
      ["T-2: feature work", "2026-10-17T11:00:00+05:30"],
      ["T-1: base", "2026-10-17T10:00:00+05:30"],
    ]);
    assert.match(before.commits[0].sha, /^[0-9a-f]{7,}$/);
    assert.deepEqual(before.release, { tag: "v0.1.0", shipped: false, shipped_at: null });

    o.commit("T-3: ship it", "2026-10-19T20:30:00+05:30");
    o.git("tag", "-a", "v0.1.0", "-m", "v0.1.0");
    const after = collectGit({ cacheDir: o.cacheDir, remote: o.origin });
    assert.equal(after.commits[0].message, "T-3: ship it");
    assert.deepEqual(after.release, { tag: "v0.1.0", shipped: true, shipped_at: "2026-10-19T20:30:00+05:30" });
    assert.notEqual(parseStatus(buildStatus({ runDir: run("qa-fail"), notePath: run("notes") + "busy.md", git: after, now: NOW })), null);
  } finally { rmSync(o.dir, { recursive: true, force: true }); }
});

test("git collector: feature branch deleted on origin after the merge still reports the tag", () => {
  const o = makeOrigin();
  try {
    collectGit({ cacheDir: o.cacheDir, remote: o.origin });
    o.git("checkout", "--quiet", "main");
    o.git("merge", "--quiet", "--no-edit", "feature/jarvis-ambient-memory");
    o.commit("T-3: ship it", "2026-10-19T20:30:00+05:30");
    o.git("tag", "-a", "v0.1.0", "-m", "v0.1.0");
    o.git("branch", "-D", "feature/jarvis-ambient-memory");
    const after = collectGit({ cacheDir: o.cacheDir, remote: o.origin });
    assert.equal(after.commits[0].message, "T-3: ship it");
    assert.deepEqual(after.release, { tag: "v0.1.0", shipped: true, shipped_at: "2026-10-19T20:30:00+05:30" });
  } finally { rmSync(o.dir, { recursive: true, force: true }); }
});

test("git collector: a cache dir that is not a bare repo is removed and cloned again", () => {
  const o = makeOrigin();
  try {
    mkdirSync(o.cacheDir, { recursive: true });
    writeFileSync(join(o.cacheDir, "junk.txt"), "half-written cache");
    const facts = collectGit({ cacheDir: o.cacheDir, remote: o.origin });
    assert.equal(facts.commits.length, 3);
    assert.equal(existsSync(join(o.cacheDir, "junk.txt")), false);
  } finally { rmSync(o.dir, { recursive: true, force: true }); }
});

const CLI = fileURLToPath(new URL("../status/compute.mjs", import.meta.url));
const cli = (o, runName, out) => {
  try {
    const stdout = execFileSync(process.execPath, [CLI, "--out", out, "--run-dir", run(runName),
      "--note", run("notes") + "other-41.md", "--cache-dir", o.cacheDir, "--remote", o.origin],
      { encoding: "utf8", stdio: "pipe" });
    return { code: 0, stdout };
  } catch (e) { return { code: e.status, stdout: e.stdout, stderr: e.stderr }; }
};

// Every file under the given paths: relative path, mtime and content hash.
const snapshot = (...roots) => roots.flatMap((root) =>
  readdirSync(root, { recursive: true }).sort().map((rel) => join(root, rel))
    .filter((p) => statSync(p).isFile())
    .map((p) => [p, statSync(p).mtimeMs, createHash("sha256").update(readFileSync(p)).digest("hex")]));

test("CLI writes only --out and prints nothing; on a bad run it writes nothing and exits 1", () => {
  const o = makeOrigin();
  try {
    const out = join(o.dir, "status.json");
    const inputs = [run("qa-partial"), run("bad-json"), run("notes")];
    const before = snapshot(...inputs);
    const ok = cli(o, "qa-partial", out);
    assert.deepEqual([ok.code, ok.stdout], [0, ""]);
    const s = parseStatus(readFileSync(out, "utf8"));
    assert.equal(s?.build.tests, 12);
    assert.equal(s.launch.note, "the notary queue is slow tonight, sorry…");

    const badOut = join(o.dir, "bad.json");
    const bad = cli(o, "bad-json", badOut);
    assert.equal(bad.code, 1);
    assert.match(bad.stderr, /status job: .*run\.json/);
    assert.equal(existsSync(badOut), false);
    assert.deepEqual(snapshot(...inputs), before);
  } finally { rmSync(o.dir, { recursive: true, force: true }); }
});

test("importing the job from a script with no file path does not run the CLI", () => {
  const out = execFileSync(process.execPath, ["--input-type=module", "-e",
    `const m = await import(${JSON.stringify(CLI)}); console.log(typeof m.buildStatus);`], { encoding: "utf8" });
  assert.equal(out, "function\n");
});
