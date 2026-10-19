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

function open(plateId) {
  const plate = PLATES.find((p) => p.id === plateId);
  if (openId) close();
  openId = plateId;
  const button = plateButton(plateId);
  button.setAttribute("aria-expanded", "true");
  button.classList.add("popped");

  const legend = document.createElement("legend");
  legend.textContent = plate.name;
  const rows = plate.options.map((o) => {
    const input = document.createElement("input");
    Object.assign(input, { type: "radio", name: `engine-${plate.id}`, value: o.id, checked: ticks[plate.id] === o.id });
    const label = document.createElement("label");
    label.append(input, o.label);
    return label;
  });
  fieldset.replaceChildren(legend, ...rows);
  fieldset.querySelector("input:checked").focus();
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
