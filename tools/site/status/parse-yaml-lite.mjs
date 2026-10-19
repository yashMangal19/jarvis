// Reads only the two flat QA shapes the build run writes. Not a YAML parser: any other shape is out of scope.

// The run writes single-quoted scalars only.
const unquote = (v) => {
  const s = v.trim();
  if (s.startsWith("'") && s.endsWith("'")) return s.slice(1, -1).replaceAll("''", "'");
  return s;
};

// Ids of the spec-moment cases in qa/cases.yaml: entries of the top-level `cases:` list that carry no
// per-case `moment: ticket` (those were written per ticket, after the spec). None at all is drift: throws.
export function specCaseIds(text) {
  const ids = new Set();
  let inCases = false;
  let id = null;
  for (const line of text.split("\n")) {
    if (/^\S/.test(line) && !line.startsWith("- ")) { inCases = line.startsWith("cases:"); id = null; continue; }
    if (!inCases) continue;
    const m = /^- case_id:(.*)$/.exec(line);
    if (m) ids.add(id = unquote(m[1]));
    else if (id && /^  moment:\s*ticket\s*$/.test(line)) ids.delete(id);
  }
  if (!ids.size) throw new Error("cases.yaml: no spec cases under a top-level cases: list");
  return ids;
}

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
