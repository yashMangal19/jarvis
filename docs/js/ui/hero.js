// p. 1: countdown, gauge needle, build log and the launch state, from the status feed and a minute tick.
// The state is one attribute on #p1 that CSS reads. Nothing below the hero moves between states because
// hero.css reserves the tallest post-deadline height on .countdown.
import { subscribe } from "../status-feed.js";
import { launchState } from "../logic/launch.js";
import { ageLabel } from "../logic/status.js";

const p1 = document.getElementById("p1");
const one = (name) => p1.querySelector(`[data-slot="${name}"]`);
// Rewrite only on change, so the polite live region announces only what moved.
const put = (el, text) => { if (el.textContent !== text) el.textContent = text; };
// "" leaves the dashed empty box: no number is shown that is not real.
const num = (v) => (v === undefined ? "" : String(v));

let last = null;

function render(s, now) {
  last = s;
  const st = launchState(now, s);
  p1.dataset.state = st.state;
  p1.style.setProperty("--needle", st.needle);
  if (st.countdown) {
    for (const k of ["days", "hours", "minutes"]) put(one(k), String(st.countdown[k]));
  }
  put(one("launch-line"), st.line ?? "till it goes online");
  put(one("stamp-suffix"), st.suffix ?? "");
  const reason = one("reason-line");
  put(reason, st.reason ?? "");
  reason.hidden = !st.reason; // late with no note: no reason line
  one("busy-art").hidden = !st.showBusyArt;

  put(one("waves-done"), num(s?.build.waves_done));
  put(one("waves-total"), num(s?.build.waves_total));
  put(one("tests-green"), num(s?.build.tests));
  put(one("last-commit-age"), s?.commits[0] ? ageLabel(s.commits[0].at, now) : "");
}

render(null, Date.now()); // the countdown runs before (and without) a status
subscribe(render);
const tick = () => render(last, Date.now());
// Ticks 1 ms past each :00. The remaining time is floored, so the shown minute drops just after :00.
setTimeout(() => { tick(); setInterval(tick, 60e3); }, 60e3 - (Date.now() % 60e3) + 1);
