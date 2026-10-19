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

// The result (stamp + line) goes in an aria-live="polite" region whose content each answer replaces.
// T-9 left no live region on p. 5, and index.html is not this ticket's file, so it is built here.
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

let token = 0;
let current = null;

function reset() {
  for (const name of ["mic", "wave", "transcript", "read-back", "answer", "stamp"]) slot(name).hidden = true;
  line.textContent = "";
  for (const b of [slot("yes"), slot("no")]) b.removeAttribute("aria-disabled");
}

function pick(id) {
  current = id;
  reset();
  for (const s of page.querySelectorAll('[data-slot="slip"]')) s.setAttribute("aria-pressed", String(s.value === id));
  slot("transcript").textContent = page.querySelector(`[data-slot="slip"][value="${id}"]`).textContent;
}

function run(id) {
  const mine = ++token;
  pick(id);

  let at = 0;
  for (const [name, ms] of STEPS) {
    at += reduced.matches ? 0 : ms;
    setTimeout(() => { if (mine === token) slot(name).hidden = false; }, at);
  }
  setTimeout(() => { if (mine === token) showCard(SLIPS[id]); }, at);
}

// The wave → card arrow runs from the wave's right edge to the card's bottom-left corner (D5). Its tip is fixed to the
// corner by CSS; here the tail is aimed at the wave, which depends on both boxes, so --w (length) and --turn are set
// from layout. offset* ignores transforms (a hidden step is nudged 6px, the card is tilted 1deg), so the answer is the
// settled one. Hidden single-column layouts hide the arrow and this costs nothing.
const TAIL = { x: 5.65 / 160, y: 34.25 / 60 }, TIP = { x: 150 / 160, y: 28 / 60 }; // arrow-r.svg, as fractions of its box
const at = (el) => { let x = 0, y = 0; for (let e = el; e; e = e.offsetParent) { x += e.offsetLeft; y += e.offsetTop; } return { x, y }; };
function aim() {
  const wave = slot("wave").querySelector("img");
  const from = { x: at(wave).x + wave.offsetWidth + 14, y: at(wave).y + wave.offsetHeight / 2 };
  for (const card of [slot("read-back"), slot("answer")]) {
    const tip = { x: at(card).x, y: at(card).y + card.offsetHeight };
    const m = new DOMMatrix(getComputedStyle(card).transform), tilt = Math.atan2(m.b, m.a); // the card's own turn
    const length = Math.hypot(tip.x - from.x, tip.y - from.y);
    const art = Math.hypot((TIP.x - TAIL.x) * 160, (TIP.y - TAIL.y) * 60), artTurn = Math.atan2((TIP.y - TAIL.y) * 60, (TIP.x - TAIL.x) * 160);
    const arrow = card.querySelector(".to-card");
    arrow.style.setProperty("--w", `${Math.max(length, 40) / art * 160}px`);
    arrow.style.setProperty("--turn", `${(Math.atan2(tip.y - from.y, tip.x - from.x) - artTurn - tilt) * 180 / Math.PI}deg`);
  }
}

function showCard(s) {
  if (s.kind === "question") {
    slot("answer-text").textContent = s.answer;
    slot("answer-source").textContent = s.source;
    slot("answer").hidden = false;
  } else {
    slot("read-back-text").textContent = s.readBack;
    slot("stamp").textContent = s.stamp; // still hidden: its box is reserved at its real size until yes
    slot("read-back").hidden = false;
  }
  aim();
}

function settle(yes) {
  if (slot("read-back").hidden || slot("yes").hasAttribute("aria-disabled")) return;
  const s = SLIPS[current];
  // aria-disabled, not disabled: the pressed button keeps focus.
  for (const b of [slot("yes"), slot("no")]) b.setAttribute("aria-disabled", "true");
  if (yes) {
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
// p. 5 opens the way D5/M5 draw it: priya already read back, waiting for yes or no. Shown at once, no timers.
pick("priya");
for (const [name] of STEPS) slot(name).hidden = false;
showCard(SLIPS.priya);
// The card slot is a polite live region too: its read-back or answer content is replaced on each run.
// Marked after the opening card is in, so loading the page announces nothing.
page.querySelector(".card-slot").setAttribute("aria-live", "polite");
addEventListener("resize", aim);
document.fonts?.ready.then(aim); // the hand and typed faces change line lengths, so card heights
