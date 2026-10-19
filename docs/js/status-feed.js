// status.json, fetched on load and every 5 min. Subscribers get the last good copy (null until one
// arrives), so a failed later fetch keeps the numbers already shown.
import { parseStatus } from "./logic/status.js";

const URL = "https://raw.githubusercontent.com/yashMangal19/jarvis/status/status.json";
let last = null;
const subs = [];

async function tick() {
  let s = null;
  try {
    const r = await fetch(`${URL}?t=${Date.now()}`, { cache: "no-store" });
    s = r.ok ? parseStatus(await r.text()) : null;
  } catch { /* offline: keep `last` */ }
  if (s) last = s;
  const now = Date.now();
  subs.forEach((fn) => fn(last, now));
}

// fn(status | null, now)
export const subscribe = (fn) => { subs.push(fn); };

export function start() {
  tick();
  setInterval(tick, 5 * 60e3);
}
