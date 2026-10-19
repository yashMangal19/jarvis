// Computes status.json (schema v1) from the build run, the QA files, git facts and the launch note.
// Run-file drift throws: the CLI logs it and writes nothing. It never guesses.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { parseArgs } from "node:util";
import { pathToFileURL } from "node:url";
import { countCases, parseResults } from "./parse-yaml-lite.mjs";
import { collectGit } from "./collect-git.mjs";

const DEADLINE = "2026-10-19T21:00:00+05:30";
const NOTE_KINDS = ["busy", "qa", "bugs"];

const readJson = (path) => {
  try { return JSON.parse(readFileSync(path, "utf8")); } catch (e) { throw new Error(`${path}: ${e.message}`); }
};

function build(runDir) {
  const run = readJson(join(runDir, "run.json"));
  const tickets = readJson(join(runDir, "tickets", "_tickets_output.json")).tickets;
  if (!Array.isArray(run.tickets) || !run.tickets.every((t) => typeof t?.id === "string" && typeof t.status === "string"))
    throw new Error("run.json: tickets[] is not a list of {id, status}");
  if (!Array.isArray(tickets) || !tickets.every((t) => typeof t?.id === "string" && Array.isArray(t.blocked_by)))
    throw new Error("_tickets_output.json: tickets[] is not a list of {id, blocked_by}");
  const done = new Set(run.tickets.filter((t) => t.status === "done").map((t) => t.id));

  // Level = 1 + the deepest blocker's level. A wave is done when all of its tickets are, in any order.
  const byId = new Map(tickets.map((t) => [t.id, t]));
  const level = new Map();
  const levelOf = (id, seen = new Set()) => {
    if (level.has(id)) return level.get(id);
    const t = byId.get(id);
    if (!t || seen.has(id)) throw new Error(`_tickets_output.json: unknown ticket or cycle at ${id}`);
    seen.add(id);
    const l = 1 + Math.max(0, ...t.blocked_by.map((b) => levelOf(b, seen)));
    level.set(id, l);
    return l;
  };
  tickets.forEach((t) => levelOf(t.id));
  const waves = Map.groupBy(tickets, (t) => level.get(t.id));

  return {
    waves_done: [...waves.values()].filter((w) => w.every((t) => done.has(t.id))).length,
    waves_total: waves.size,
    tickets_done: tickets.filter((t) => done.has(t.id)).length,
    tickets_total: tickets.length,
    tests: tests(join(runDir, "progress.jsonl")),
  };
}

function tests(path) {
  if (!existsSync(path)) return 0;
  const events = readFileSync(path, "utf8").split("\n").flatMap((l) => {
    try { return [JSON.parse(l)]; } catch { return []; } // blank line, or an append still in flight
  });
  const gate = events.findLast((e) => e?.kind === "gate" && /(\d+) tests?/.test(e.note));
  return gate ? Number(/(\d+) tests?/.exec(gate.note)[1]) : 0;
}

function qa(runDir) {
  const total = countCases(readFileSync(join(runDir, "qa", "cases.yaml"), "utf8"));
  const counts = { pass: 0, fail: 0, blocked: 0 };
  const resultsPath = join(runDir, "qa", "results.yaml");
  if (!existsSync(resultsPath)) return { total, ...counts };
  const latest = new Map();
  for (const r of parseResults(readFileSync(resultsPath, "utf8"))) {
    const prev = latest.get(r.case_id);
    if (!prev || Date.parse(r.at) >= Date.parse(prev.at)) latest.set(r.case_id, r);
  }
  for (const { result } of latest.values()) if (result in counts) counts[result]++;
  return { total, ...counts };
}

function launch(notePath) {
  let line;
  try { line = readFileSync(notePath, "utf8").split("\n")[0].trim(); } catch { line = ""; }
  const other = /^other:\s*(.+)/.exec(line);
  if (other) {
    const text = other[1].trim();
    return { deadline: DEADLINE, note_kind: "other", note: text.length > 40 ? text.slice(0, 39) + "…" : text };
  }
  return { deadline: DEADLINE, note_kind: NOTE_KINDS.includes(line) ? line : null, note: null };
}

export function buildStatus({ runDir, notePath, git, now }) {
  return {
    schema: 1,
    generated_at: new Date(now).toISOString(),
    build: build(runDir),
    qa: qa(runDir),
    commits: git.commits,
    release: git.release,
    launch: launch(notePath),
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const home = homedir();
  const { values: o } = parseArgs({ options: {
    out: { type: "string" },
    "run-dir": { type: "string", default: join(home, "jarvis/.agentic/jarvis-ambient-memory") },
    note: { type: "string", default: join(home, "jarvis/.agentic/jarvis-site/launch-note.md") },
    "cache-dir": { type: "string", default: join(home, "Library/Caches/jarvis-site-status/repo.git") },
    remote: { type: "string", default: "https://github.com/yashMangal19/jarvis.git" },
  } });
  try {
    if (!o.out) throw new Error("--out <file> is required");
    const git = collectGit({ cacheDir: o["cache-dir"], remote: o.remote });
    const status = buildStatus({ runDir: o["run-dir"], notePath: o.note, git, now: Date.now() });
    writeFileSync(o.out, JSON.stringify(status, null, 2) + "\n");
  } catch (e) {
    console.error(`status job: ${e.message}`);
    process.exitCode = 1;
  }
}
