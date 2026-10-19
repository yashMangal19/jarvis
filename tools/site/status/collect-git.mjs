// Git facts for status.json, from a private blobless bare cache. Never touches the main checkout.
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";

const BRANCHES = ["main", "feature/jarvis-ambient-memory"];
const TAG = "v0.1.0";

export function collectGit({ cacheDir, remote }) {
  const git = (...args) => execFileSync("git", [`--git-dir=${cacheDir}`, ...args], { encoding: "utf8" }).trim();
  if (!existsSync(cacheDir))
    execFileSync("git", ["clone", "--quiet", "--bare", "--filter=blob:none", remote, cacheDir], { stdio: "pipe" });
  git("fetch", "--quiet", "--tags", "--force", "origin",
    ...BRANCHES.map((b) => `+refs/heads/${b}:refs/remotes/origin/${b}`));

  // One log over both refs: git merges them by date and lists a shared commit once.
  const log = git("log", "-5", "--format=%h%x1f%s%x1f%cI", ...BRANCHES.map((b) => `origin/${b}`));
  const commits = log ? log.split("\n").map((l) => {
    const [sha, message, at] = l.split("\x1f");
    return { sha, message, at };
  }) : [];

  const shipped = git("ls-remote", "--tags", "origin", TAG) !== "";
  const shipped_at = shipped ? git("log", "-1", "--format=%cI", `${TAG}^{}`) : null;
  return { commits, release: { tag: TAG, shipped, shipped_at } };
}
