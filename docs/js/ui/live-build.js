// p. 3: wave ticks, counts, commits and the update line, from the status feed.
import { subscribe } from "../status-feed.js";
import { freshness, liveLine, ageLabel } from "../logic/status.js";

const p3 = document.getElementById("p3");
const all = (slot) => p3.querySelectorAll(`[data-slot="${slot}"]`);
// Rewrite only on change, so the polite live region announces only what moved.
const put = (el, text) => { if (el.textContent !== text) el.textContent = text; };
// "" leaves the dashed empty box: no number is shown that is not real.
const num = (v) => (v === undefined ? "" : String(v));

subscribe((s, now) => {
  put(all("updates-line")[0], liveLine(s, now));
  const note = s && freshness(s, now).note;
  const stale = all("stale-note")[0];
  put(stale, note ?? "");
  stale.hidden = !note;

  const done = s?.build.waves_done ?? 0;
  all("wave-boxes")[0].querySelectorAll("img").forEach((img, i) => {
    const src = `assets/art/${i < done ? "box-tick" : "box"}.svg`;
    if (img.getAttribute("src") !== src) img.setAttribute("src", src);
  });
  put(all("waves-done")[0], num(s?.build.waves_done));
  put(all("tests-green")[0], num(s?.build.tests));
  put(all("hand-checks-pass")[0], num(s?.qa.pass));
  const total = all("hand-checks-total")[0];
  put(total, num(s?.qa.total));
  total.classList.toggle("slot", !s);

  const ages = all("commit-age");
  const msgs = all("commit-msg");
  ages.forEach((age, i) => {
    const c = s?.commits[i];
    put(age, c ? ageLabel(c.at, now) : "");
    age.classList.toggle("slot", !s);
    put(msgs[i], c?.message ?? "");
  });
});
