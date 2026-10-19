// p. 5: a scripted demo. No mic, no backend: picking a slip plays mic → wave → transcript → card.
const SLIPS = {
  reminder: { kind: "command", readBack: "I’ll remind you to call mom at 7 pm.\nset it?",
    stamp: "DONE ✓", line: "reminder set for 7 pm" },
  priya: { kind: "command", readBack: "I’ll message Priya:\n“running 10 min late.”\nsend it?", stamp: "SENT ✓" },
  pricing: { kind: "question", answer: "you settled on ₹499 a month, starting november.",
    source: "from tuesday's 3 pm note" },
};
const STEPS = [["mic", 400], ["wave", 500], ["transcript", 600]];

const page = document.querySelector("#p5");
const slot = (name) => page.querySelector(`[data-slot="${name}"]`);
const reduced = matchMedia("(prefers-reduced-motion: reduce)");

// The result (stamp + line) sits in one polite live region; T-9 left none on p. 5 and index.html is not ours.
const result = document.createElement("div");
result.className = "result";
result.dataset.slot = "result";
result.setAttribute("aria-live", "polite");
const line = document.createElement("p");
line.className = "result-line hand red";
line.dataset.slot = "result-line";
const stamp = slot("stamp");
stamp.replaceWith(result);
result.append(stamp, line);
// The cards are what the demo says back, so they are announced as they appear.
page.querySelector(".card-slot").setAttribute("aria-live", "polite");

let token = 0;
let current = null;

function reset() {
  for (const name of ["mic", "wave", "transcript", "read-back", "answer", "stamp"]) slot(name).hidden = true;
  line.textContent = "";
  for (const b of [slot("yes"), slot("no")]) b.removeAttribute("aria-disabled");
}

function run(id) {
  const mine = ++token;
  current = id;
  reset();
  for (const s of page.querySelectorAll('[data-slot="slip"]')) s.setAttribute("aria-pressed", String(s.value === id));
  slot("transcript").textContent = page.querySelector(`[data-slot="slip"][value="${id}"]`).textContent;

  let at = 0;
  for (const [name, ms] of STEPS) {
    at += reduced.matches ? 0 : ms;
    setTimeout(() => { if (mine === token) slot(name).hidden = false; }, at);
  }
  setTimeout(() => { if (mine === token) showCard(SLIPS[id]); }, at);
}

function showCard(s) {
  if (s.kind === "question") {
    slot("answer-text").textContent = s.answer;
    slot("answer-source").textContent = s.source;
    slot("answer").hidden = false;
  } else {
    slot("read-back-text").textContent = s.readBack;
    slot("read-back").hidden = false;
  }
}

function settle(yes) {
  if (slot("read-back").hidden || slot("yes").hasAttribute("aria-disabled")) return;
  const s = SLIPS[current];
  // aria-disabled, not disabled: the pressed button keeps focus.
  for (const b of [slot("yes"), slot("no")]) b.setAttribute("aria-disabled", "true");
  if (yes) {
    slot("stamp").textContent = s.stamp;
    slot("stamp").hidden = false;
    line.textContent = s.line ?? "";
  } else {
    line.textContent = "cancelled. nothing left your mac.";
  }
}

page.addEventListener("click", (e) => {
  const b = e.target.closest("button");
  if (b?.dataset.slot === "slip") run(b.value);
  else if (b?.dataset.slot === "yes") settle(true);
  else if (b?.dataset.slot === "no") settle(false);
});
for (const s of page.querySelectorAll('[data-slot="slip"]')) s.setAttribute("aria-pressed", "false");
