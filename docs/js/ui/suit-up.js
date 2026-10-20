// p. 4: pop a plate out, tick one engine per plate on its index card, recompute the offline line.
// Reads PLATES and never writes to it: every plate shares one "own" row object.
import { PLATES, defaultTicks, offlineLine } from "../logic/plates.js";

const p4 = document.getElementById("p4");
const fieldset = p4.querySelector('[data-slot="plate-options"]');
const line = p4.querySelector('[data-slot="offline-line"]');
const plateButton = (id) => p4.querySelector(`[data-slot="plate"][value="${id}"]`);

const ticks = defaultTicks();
let openId = null;
line.textContent = offlineLine(ticks);

function close() {
  const button = plateButton(openId);
  button.setAttribute("aria-expanded", "false");
  fieldset.replaceChildren();
  openId = null;
  return button;
}

// One card's contents. live: false builds a measuring copy: no radio names or ids, so it can never join
// the real card's radio groups or descriptions.
function card(plate, { live = true } = {}) {
  const legend = document.createElement("legend");
  legend.textContent = plate.name;
  const tagline = document.createElement("p");
  tagline.className = "tagline hand";
  // Both lines are in the card; CSS shows the short one on a phone, where the long one would wrap.
  tagline.append(...[["long", plate.tagline], ["short", plate.shortTagline]].filter(([, text]) => text)
    .map(([className, textContent]) => Object.assign(document.createElement("span"), { className, textContent })));
  // A real radio inside each label keeps the keyboard and screen-reader behaviour; CSS draws the box over it.
  const rows = plate.options.map((o) => {
    const noteId = `note-${plate.id}-${o.id}`;
    const input = document.createElement("input");
    Object.assign(input, { type: "radio", value: o.id, checked: ticks[plate.id] === o.id });
    const note = document.createElement("span");
    Object.assign(note, { className: "note", textContent: o.note });
    if (live) {
      input.name = `engine-${plate.id}`;
      input.setAttribute("aria-describedby", noteId);
      note.id = noteId;
    }
    const label = document.createElement("label");
    label.append(input, o.label);
    const option = document.createElement("div");
    option.className = "option";
    option.append(label, note);
    return option;
  });
  return [legend, tagline, ...rows];
}

// focus: false fills the card without pulling the page to it (the load default below).
function open(plateId, { focus = true } = {}) {
  const plate = PLATES.find((p) => p.id === plateId);
  if (openId) close();
  openId = plateId;
  plateButton(plateId).setAttribute("aria-expanded", "true");
  fieldset.replaceChildren(...card(plate));
  if (focus) fieldset.querySelector("input:checked").focus();
}

// The card hugs its rows. The column around it (card + the row of other plates) is as tall as it would be with the
// tallest plate's card, so the row of other plates never moves. The tallest is measured in a hidden copy, because
// rows wrap differently at each width.
const cardEl = fieldset.closest(".index-card"), column = cardEl.parentElement, others = column.querySelector(".others");
// Fractional layout heights (offsetHeight rounds, and a 1px drift would move the row).
const heightOf = (el) => parseFloat(getComputedStyle(el).height);
function reserve() {
  const probe = Object.assign(fieldset.cloneNode(false), { inert: true });
  probe.removeAttribute("data-slot");
  Object.assign(probe.style, { position: "absolute", visibility: "hidden", width: `${fieldset.clientWidth}px` });
  fieldset.after(probe);
  const tallest = Math.max(...PLATES.map((p) => { probe.replaceChildren(...card(p, { live: false })); return heightOf(probe); }));
  probe.remove();
  const gap = parseFloat(getComputedStyle(cardEl).marginBottom);
  column.style.minHeight = `${heightOf(cardEl) - heightOf(fieldset) + tallest + gap + heightOf(others)}px`;
}
new ResizeObserver(reserve).observe(cardEl);
document.fonts?.ready.then(reserve);

for (const b of p4.querySelectorAll('[data-slot="plate"], [data-slot="other-plate"]')) {
  b.addEventListener("click", () => open(b.value));
}

fieldset.addEventListener("change", (e) => {
  ticks[openId] = e.target.value;
  line.textContent = offlineLine(ticks);
});

p4.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && openId) close().focus();
});

// The card is never empty: it opens on hands, the plate the design shows first.
open("hands", { focus: false });
