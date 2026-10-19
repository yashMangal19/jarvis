// p. 7: the forks list, fetched once per visit, becomes the mark cards. The default card stays until then.
import { FORKS_URL, marksFromForks } from "../logic/marks.js";

const row = document.querySelector('#p7 ol[data-slot="marks"]');
const card = row.querySelector("li.mark");

fetch(FORKS_URL)
  .then((r) => (r.ok ? r.json() : null))
  .catch(() => null)
  .then(marksFromForks)
  .then((marks) =>
    row.replaceChildren(...marks.map(({ label }) => {
      const li = card.cloneNode(true);
      li.querySelector("p").textContent = label;
      return li;
    })));
