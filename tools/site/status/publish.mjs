// The LaunchAgent's entry point: compute status.json, then publish it to the orphan `status` branch.
// Works only in a fresh temp clone; never stages anything in the main checkout. Pushes without force.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir, homedir, userInfo } from "node:os";
import { join } from "node:path";
import { isDeepStrictEqual, parseArgs } from "node:util";
import { pathToFileURL } from "node:url";
import { buildStatus } from "./compute.mjs";
import { collectGit } from "./collect-git.mjs";

const LABEL = "in.jarvis.site-status";
const HOUR = 3600_000;
const IDENTITY = ["-c", "user.name=Yash Mangal", "-c", "user.email=yash28mangal@gmail.com"];

// No prompt under launchd: a missing credential fails the push instead of hanging the job.
const git = (...args) => execFileSync("git", args, { encoding: "utf8", stdio: "pipe",
  env: { ...process.env, GIT_TERMINAL_PROMPT: "0" } }).trim();

export function main({ remote, checkout, runDir, notePath, cacheDir, now }, runner) {
  const stamp = new Date(now).toISOString();
  const tmp = mkdtempSync(join(tmpdir(), "jarvis-site-status-"));
  try {
    const origin = remote ?? git("-C", checkout, "remote", "get-url", "origin");
    try {
      git("clone", "--quiet", "--branch", "status", "--single-branch", origin, tmp);
    } catch {
      // No status branch yet: start it as an orphan. If the clone failed for another reason,
      // the no-force push below is rejected rather than overwriting anything.
      git("init", "--quiet", "-b", "status", tmp);
      git("-C", tmp, "remote", "add", "origin", origin);
    }
    const next = buildStatus({ runDir, notePath, git: runner.collect({ cacheDir, remote: origin }), now });
    const file = join(tmp, "status.json");
    let prev = null;
    try { prev = JSON.parse(readFileSync(file, "utf8")); } catch {} // a new branch, or a file to overwrite
    if (prev && isDeepStrictEqual({ ...prev, generated_at: null }, { ...next, generated_at: null })
        && now - Date.parse(prev.generated_at) < HOUR) {
      runner.log(`${stamp} skipped (unchanged)`);
      return 0;
    }
    writeFileSync(file, JSON.stringify(next, null, 2) + "\n");
    git("-C", tmp, "add", "--", "status.json");
    git("-C", tmp, ...IDENTITY, "commit", "--quiet", "-m", `status ${next.generated_at}`);
    git("-C", tmp, "push", "--quiet", "origin", "HEAD:refs/heads/status");
    runner.log(`${stamp} pushed ${git("-C", tmp, "rev-parse", "--short", "HEAD")}`);
    if (next.release.shipped) runner.bootout(`gui/${userInfo().uid}/${LABEL}`);
    return 0;
  } catch (e) {
    const msg = (e.stderr?.toString().trim() || e.message).replace(/\s*\n\s*/g, " | ");
    runner.log(`${stamp} error ${msg}`);
    return 1;
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const home = homedir();
  const { values: o } = parseArgs({ options: { remote: { type: "string" } } });
  // Same inputs as compute.mjs's CLI defaults.
  process.exitCode = main({
    remote: o.remote,
    checkout: join(home, "jarvis"),
    runDir: join(home, "jarvis/.agentic/jarvis-ambient-memory"),
    notePath: join(home, "jarvis/.agentic/jarvis-site/launch-note.md"),
    cacheDir: join(home, "Library/Caches/jarvis-site-status/repo.git"),
    now: Date.now(),
  }, {
    log: console.log,
    collect: collectGit,
    bootout: (target) => execFileSync("launchctl", ["bootout", target], { stdio: "pipe" }),
  });
}
