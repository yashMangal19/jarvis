// status.json (schema v1): accept or reject, and say how fresh it is. Pure: no DOM, no clock.

const NOTE_KINDS = [null, "busy", "qa", "bugs", "other"];

const isNum = (v) => typeof v === "number" && Number.isFinite(v);
const isStr = (v) => typeof v === "string";
const isDate = (v) => isStr(v) && !Number.isNaN(Date.parse(v));
const nums = (o, keys) => o != null && keys.every((k) => isNum(o[k]));

function isValid(s) {
  const { build, qa, commits, release: r, launch: l } = s;
  return isDate(s.generated_at)
    && nums(build, ["waves_done", "waves_total", "tickets_done", "tickets_total", "tests"])
    && nums(qa, ["total", "pass", "fail", "blocked"])
    && Array.isArray(commits)
    && commits.every((c) => isStr(c?.sha) && isStr(c.message) && isDate(c.at))
    && r != null && isStr(r.tag) && typeof r.shipped === "boolean"
    && (r.shipped_at === null ? !r.shipped : isDate(r.shipped_at))
    && l != null && isDate(l.deadline)
    && NOTE_KINDS.includes(l.note_kind) && (l.note === null || isStr(l.note));
}

// Returns the status, or null when it is not JSON, not schema 1, or any field is missing or mistyped.
export function parseStatus(input) {
  let s = input;
  if (typeof input === "string") {
    try { s = JSON.parse(input); } catch { return null; }
  }
  return s?.schema === 1 && isValid(s) ? s : null;
}

export function freshness(status, now) {
  const ageHours = (Number(now) - Date.parse(status.generated_at)) / 3.6e6;
  const stale = !status.release.shipped && ageHours > 2;
  return { stale, ageHours, note: stale ? `last update ${Math.floor(ageHours)} h ago` : null };
}

const IST_DAY = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", timeZone: "Asia/Kolkata" });

// The live-build footer line. `status` is parseStatus output (null = missing).
export function liveLine(status, now) {
  if (status === null) return "status offline";
  if (!status.release.shipped) return "updates itself every hour";
  return `final numbers · shipped ${IST_DAY.format(new Date(status.release.shipped_at)).toLowerCase()}`;
}

// A commit's age as the page prints it: "18m ago", "3h ago", "2d ago".
export function ageLabel(at, now) {
  const minutes = Math.max(0, Math.floor((Number(now) - Date.parse(at)) / 60e3));
  if (minutes < 60) return `${minutes}m ago`;
  if (minutes < 48 * 60) return `${Math.floor(minutes / 60)}h ago`;
  return `${Math.floor(minutes / (24 * 60))}d ago`;
}
