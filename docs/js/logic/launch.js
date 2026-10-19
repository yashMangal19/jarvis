// The hero's launch state from (now, status | null). Pure: no DOM, instants only.

const MIN = 60_000;
const HOUR = 60 * MIN;
const DEADLINE = Date.parse("2026-10-19T21:00:00+05:30");
export const LABEL = "mon 19 oct, 9 pm IST"; // fixed wording, never the visitor's zone

function splitDHM(ms) {
  const minutes = Math.floor(ms / MIN);
  return { days: Math.floor(minutes / 1440), hours: Math.floor(minutes / 60) % 24, minutes: minutes % 60 };
}

const REASONS = {
  busy: "yash got pulled away. jarvis waits for him.",
  qa: "still checking every bolt by hand.",
  bugs: "found loose screws. tightening them.",
};

const needle = (s) => (s && s.qa.total > 0 ? s.qa.pass / s.qa.total : 0);

export function launchState(now, s) {
  const t = Number(now);
  if (s?.release.shipped) {
    const d = DEADLINE - Date.parse(s.release.shipped_at);
    const h = Math.floor(Math.abs(d) / HOUR);
    return { state: "online", suffix: h < 1 ? null : `shipped ${h} h ${d > 0 ? "early" : "late"}`, needle: 1 };
  }
  if (t < DEADLINE) return { state: "countdown", countdown: splitDHM(DEADLINE - t), needle: needle(s) };
  if (!s) return { state: "late-unknown", line: "running late · status offline", needle: 0 };
  const late = t - DEADLINE;
  const by = late < HOUR ? `${Math.floor(late / MIN)} min` : `${Math.floor(late / HOUR)} h`;
  const kind = s.launch.note_kind ?? (s.qa.fail > 0 ? "bugs" : "qa");
  return {
    state: "late",
    line: `running late by ${by} · Final checks ${s.qa.pass}/${s.qa.total}`,
    reason: kind === "other" ? s.launch.note : REASONS[kind],
    showBusyArt: kind === "busy",
    needle: needle(s),
  };
}
