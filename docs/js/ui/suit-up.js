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
  button.classList.remove("popped");
  fieldset.replaceChildren();
  openId = null;
  return button;
}

// focus: false fills the card without pulling the page to it (the load default below).
function open(plateId, { focus = true } = {}) {
  const plate = PLATES.find((p) => p.id === plateId);
  if (openId) close();
  openId = plateId;
  const button = plateButton(plateId);
  button.setAttribute("aria-expanded", "true");
  button.classList.add("popped");

  const legend = document.createElement("legend");
  legend.textContent = plate.name;
  const tagline = document.createElement("p");
  tagline.className = "tagline hand";
  tagline.textContent = plate.tagline;
  // A real radio inside each label keeps the keyboard and screen-reader behaviour; CSS draws the box over it.
  const rows = plate.options.map((o) => {
    const noteId = `note-${plate.id}-${o.id}`;
    const input = document.createElement("input");
    Object.assign(input, { type: "radio", name: `engine-${plate.id}`, value: o.id, checked: ticks[plate.id] === o.id });
    input.setAttribute("aria-describedby", noteId);
    const label = document.createElement("label");
    label.append(input, o.label);
    const note = document.createElement("span");
    Object.assign(note, { id: noteId, className: "note", textContent: o.note });
    const option = document.createElement("div");
    option.className = "option";
    option.append(label, note);
    return option;
  });
  fieldset.replaceChildren(legend, tagline, ...rows);
  if (focus) fieldset.querySelector("input:checked").focus();
}

for (const b of p4.querySelectorAll('[data-slot="plate"], [data-slot="other-plate"]')) {
  b.addEventListener("click", () => open(b.value));
}

fieldset.addEventListener("change", (e) => {
  ticks[openId] = e.target.value;
  plateButton(openId).classList.remove("popped");
  line.textContent = offlineLine(ticks);
});

p4.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && openId) close().focus();
});

// The card is never empty: it opens on hands, the plate the design shows first.
open("hands", { focus: false });
