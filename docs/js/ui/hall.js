// p. 7: the forks list becomes the mark cards. The default card stays until then.
// Unauthenticated, the API allows 60 requests an hour per IP, so the answer (a failure included) is
// kept for the session: a reload or a second visit within TTL_MS makes no request.
import { FORKS_URL, marksFromForks } from "../logic/marks.js";

const row = document.querySelector('#p7 ol[data-slot="marks"]');
const card = row.querySelector("li.mark");
const KEY = "jarvis.marks";
const TTL_MS = 10 * 60 * 1000;

// Storage can throw (blocked or full); then every load simply fetches.
function cached() {
  try {
    const { at, marks } = JSON.parse(sessionStorage.getItem(KEY));
    return Date.now() - at < TTL_MS ? marks : null;
  } catch {
    return null;
  }
}

function fetchMarks() {
  return fetch(FORKS_URL)
    .then((r) => (r.ok ? r.json() : null))
    .catch(() => null)
    .then(marksFromForks)
    .then((marks) => {
      try { sessionStorage.setItem(KEY, JSON.stringify({ at: Date.now(), marks })); } catch {}
      return marks;
    });
}

Promise.resolve(cached() ?? fetchMarks()).then((marks) =>
  row.replaceChildren(...marks.map(({ label }) => {
    const li = card.cloneNode(true);
    const [name, handle] = li.querySelectorAll("p > span");
    [name.textContent, handle.textContent] = label.split(" · ");
    return li;
  })));
