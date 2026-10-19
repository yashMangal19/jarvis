// status.json, fetched on load and every 5 min. Subscribers get the last good copy (null until one
// arrives), so a failed later fetch keeps the numbers already shown.
import { parseStatus } from "./logic/status.js";

const URL = "https://raw.githubusercontent.com/yashMangal19/jarvis/status/status.json";
let last = null;
let inFlight = false;
const subs = [];

async function tick() {
  if (inFlight) return;
  inFlight = true;
  // AbortController + setTimeout rather than AbortSignal.timeout, so page.clock can drive it in the smoke.
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), 20e3);
  let s = null;
  try {
    const r = await fetch(`${URL}?t=${Date.now()}`, { cache: "no-store", signal: abort.signal });
    s = r.ok ? parseStatus(await r.text()) : null;
  } catch { /* offline or timed out: keep `last` */ }
  clearTimeout(timer);
  inFlight = false;
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
