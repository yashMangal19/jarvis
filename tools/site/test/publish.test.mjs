import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { mkdtempSync, rmSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { main } from "../status/publish.mjs";
import { collectGit } from "../status/collect-git.mjs";
import { NOW } from "./fixtures/clock.mjs";

const run = (name) => fileURLToPath(new URL(`./fixtures/runs/${name}/`, import.meta.url));
const env = { ...process.env, GIT_AUTHOR_NAME: "Demo", GIT_AUTHOR_EMAIL: "demo@example.invalid",
  GIT_COMMITTER_NAME: "Demo", GIT_COMMITTER_EMAIL: "demo@example.invalid", GIT_CONFIG_GLOBAL: "/dev/null" };
const git = (...a) => execFileSync("git", ["-c", "commit.gpgsign=false", ...a], { env, encoding: "utf8", stdio: "pipe" }).trim();

// A "main checkout" whose origin is a local bare repo. The job reads the remote from the checkout.
function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "publish-test-"));
  const checkout = join(dir, "checkout");
  const remote = join(dir, "remote.git");
  git("init", "--quiet", "-b", "main", checkout);
  git("-C", checkout, "commit", "--quiet", "--allow-empty", "-m", "T-1: base");
  git("init", "--quiet", "--bare", remote);
  git("-C", checkout, "remote", "add", "origin", remote);
  git("-C", checkout, "push", "--quiet", "origin", "main");
  const logs = [];
  const bootouts = [];
  const runner = { log: (l) => logs.push(l), bootout: (t) => bootouts.push(t), collect: collectGit };
  const job = (runName, now = NOW, r = runner) => main({ checkout, runDir: run(runName),
    notePath: run("notes") + "busy.md", cacheDir: join(dir, "cache", "repo.git"), now }, r);
  const statusLog = () => git("--git-dir", remote, "log", "--format=%H", "status").split("\n");
  const statusFiles = () => git("--git-dir", remote, "ls-tree", "--name-only", "status").split("\n");
  return { dir, checkout, remote, logs, bootouts, runner, job, statusLog, statusFiles };
}

test("first run creates the orphan status branch holding only status.json", () => {
  const f = fixture();
  try {
    assert.equal(f.job("qa-fail"), 0);
    assert.deepEqual(f.statusFiles(), ["status.json"]);
    assert.equal(f.statusLog().length, 1);
    const sha = git("--git-dir", f.remote, "rev-parse", "--short", "status");
    assert.deepEqual(f.logs, [`${NOW.toISOString()} pushed ${sha}`]);
    const s = JSON.parse(git("--git-dir", f.remote, "show", "status:status.json"));
    assert.equal(s.build.tests, 40);
    assert.equal(git("--git-dir", f.remote, "log", "-1", "--format=%an <%ae>", "status"), "Yash Mangal <yash28mangal@gmail.com>");
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

const MIN = 60_000;
const leftovers = () => readdirSync(tmpdir()).filter((n) => n.startsWith("jarvis-site-status-"));

test("a second run within 1 h with unchanged numbers logs skipped and pushes nothing", () => {
  const f = fixture();
  try {
    f.job("qa-fail");
    assert.equal(f.job("qa-fail", new Date(NOW.getTime() + 59 * MIN)), 0);
    assert.equal(f.logs[1], `${new Date(NOW.getTime() + 59 * MIN).toISOString()} skipped (unchanged)`);
    assert.equal(f.statusLog().length, 1);
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

test("unchanged numbers but the committed file is an hour old: pushes a fresh generated_at", () => {
  const f = fixture();
  try {
    f.job("qa-fail");
    assert.equal(f.job("qa-fail", new Date(NOW.getTime() + 60 * MIN)), 0);
    assert.match(f.logs[1], / pushed [0-9a-f]{7,}$/);
    assert.equal(f.statusLog().length, 2);
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

test("a changed number pushes on top of the previous commit", () => {
  const f = fixture();
  try {
    f.job("qa-partial");
    assert.equal(f.job("qa-fail", new Date(NOW.getTime() + 5 * MIN)), 0);
    assert.match(f.logs[1], / pushed [0-9a-f]{7,}$/);
    assert.equal(f.statusLog().length, 2);
    assert.deepEqual(f.statusFiles(), ["status.json"]);
    assert.equal(JSON.parse(git("--git-dir", f.remote, "show", "status:status.json")).build.tests, 40);
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

test("a remote that moved on mid-run: logs an error, exits 1, does not force, leaves no temp clone", () => {
  const f = fixture();
  try {
    f.job("qa-partial");
    // Another writer pushes to status after our clone, before our push.
    const rival = join(f.dir, "rival");
    const collect = (a) => {
      git("clone", "--quiet", "--branch", "status", f.remote, rival);
      git("-C", rival, "commit", "--quiet", "--allow-empty", "-m", "rival");
      git("-C", rival, "push", "--quiet", "origin", "status");
      return collectGit(a);
    };
    const rivalHead = () => git("-C", rival, "rev-parse", "HEAD");
    assert.equal(f.job("qa-fail", NOW, { ...f.runner, collect }), 1);
    assert.match(f.logs[1], new RegExp(`^${NOW.toISOString()} error .*rejected`));
    assert.doesNotMatch(f.logs[1], /\n/);
    assert.equal(git("--git-dir", f.remote, "rev-parse", "status"), rivalHead());
    assert.deepEqual(leftovers(), []);
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

test("shipped: true triggers the bootout runner exactly once, after the push", () => {
  const f = fixture();
  try {
    f.job("qa-fail");
    git("--git-dir", f.remote, "tag", "v0.1.0", "main");
    const order = [];
    const runner = { ...f.runner, log: (l) => order.push(l), bootout: (t) => order.push(`bootout ${t}`) };
    assert.equal(f.job("qa-fail", new Date(NOW.getTime() + 5 * MIN), runner), 0);
    assert.equal(order.length, 2);
    assert.match(order[0], / pushed /);
    assert.match(order[1], /^bootout gui\/\d+\/in\.jarvis\.site-status$/);
    assert.equal(JSON.parse(git("--git-dir", f.remote, "show", "status:status.json")).release.shipped, true);
    assert.deepEqual(f.bootouts, []);
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

test("the main checkout is left clean with no new commits, and no temp clone is left behind", () => {
  const f = fixture();
  try {
    const before = git("-C", f.checkout, "for-each-ref", "--format=%(refname) %(objectname)");
    f.job("qa-partial");
    f.job("qa-fail", new Date(NOW.getTime() + 5 * MIN));
    assert.equal(git("-C", f.checkout, "status", "--porcelain", "--untracked-files=all"), "");
    assert.equal(git("-C", f.checkout, "for-each-ref", "--format=%(refname) %(objectname)"), before);
    assert.deepEqual(leftovers(), []);
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});

test("a bad run dir logs one error line, exits 1 and pushes nothing", () => {
  const f = fixture();
  try {
    assert.equal(f.job("bad-json"), 1);
    assert.match(f.logs[0], new RegExp(`^${NOW.toISOString()} error .*run\\.json`));
    assert.equal(git("--git-dir", f.remote, "for-each-ref", "refs/heads/status"), "");
    assert.deepEqual(leftovers(), []);
  } finally { rmSync(f.dir, { recursive: true, force: true }); }
});
