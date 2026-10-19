// Reads only the two flat QA shapes the build run writes. Not a YAML parser: any other shape is out of scope.

// Number of cases in qa/cases.yaml: one top-level "- case_id:" line each ("writer_case_id" lines do not count).
export const countCases = (text) => text.split("\n").filter((l) => /^\s*- case_id:/.test(l)).length;

// The run writes single-quoted scalars only.
const unquote = (v) => {
  const s = v.trim();
  if (s.startsWith("'") && s.endsWith("'")) return s.slice(1, -1).replaceAll("''", "'");
  return s;
};

// qa/results.yaml: `results:` then a flat list of { case_id, result, at, note }. Returns [{ case_id, result, at }].
export function parseResults(text) {
  const rows = [];
  for (const line of text.split("\n")) {
    const m = /^(- |  )(case_id|result|at):(.*)$/.exec(line);
    if (!m) continue;
    if (m[1] === "- ") {
      if (m[2] !== "case_id") throw new Error(`results.yaml: entry starts with ${m[2]}, not case_id`);
      rows.push({});
    } else if (!rows.length) continue;
    rows.at(-1)[m[2]] = unquote(m[3]);
  }
  return rows;
}
