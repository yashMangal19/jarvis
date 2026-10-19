// Git facts for status.json, from a private blobless bare cache. Never touches the main checkout.
import { execFileSync } from "node:child_process";
import { existsSync, rmSync } from "node:fs";
import { basename } from "node:path";

const BRANCHES = ["main", "feature/jarvis-ambient-memory"];
const TAG = "v0.1.0";

export function collectGit({ cacheDir, remote }) {
  const git = (...args) => execFileSync("git", [`--git-dir=${cacheDir}`, ...args], { encoding: "utf8", stdio: "pipe" }).trim();
  const isBare = () => { try { return git("rev-parse", "--is-bare-repository") === "true"; } catch { return false; } };
  if (existsSync(cacheDir) && !isBare()) {
    // Only a dedicated "*.git" cache path is ever deleted, so a mistyped --cache-dir cannot wipe a real folder.
    if (!basename(cacheDir).endsWith(".git")) throw new Error(`${cacheDir} is not a bare repo; refusing to delete it`);
    rmSync(cacheDir, { recursive: true, force: true });
  }
  if (!existsSync(cacheDir))
    execFileSync("git", ["clone", "--quiet", "--bare", "--filter=blob:none", remote, cacheDir], { stdio: "pipe" });
  // A wildcard refspec never fails on a missing branch, and --prune drops one deleted on origin.
  git("fetch", "--quiet", "--prune", "--tags", "--force", "origin", "+refs/heads/*:refs/remotes/origin/*");

  // One log over the branches that still exist: git merges them by date and lists a shared commit once.
  const refs = BRANCHES.map((b) => `refs/remotes/origin/${b}`)
    .filter((r) => git("for-each-ref", "--format=%(refname)", r) !== "");
  const log = refs.length ? git("log", "-5", "--format=%h%x1f%s%x1f%cI", ...refs) : "";
  const commits = log ? log.split("\n").map((l) => {
    const [sha, message, at] = l.split("\x1f");
    return { sha, message, at };
  }) : [];

  const shipped = git("ls-remote", "--tags", "origin", TAG) !== "";
  const shipped_at = shipped ? git("log", "-1", "--format=%cI", `${TAG}^{}`) : null;
  return { commits, release: { tag: TAG, shipped, shipped_at } };
}
