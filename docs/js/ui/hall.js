// p. 7: the forks list becomes the mark cards. The default card stays until then.
// Unauthenticated, the API allows 60 requests an hour per IP. So a useful answer (the forks, or a 403/429
// rate limit, which asking again would only repeat) is kept for the session: a reload or a second visit
// within TTL_MS makes no request. A network error, a bad body or a 5xx is not kept; the next load asks again.
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

async function fetchMarks() {
  let forks = null;
  let keep = false;
  try {
    const r = await fetch(FORKS_URL);
    keep = r.ok || r.status === 403 || r.status === 429;
    if (r.ok) forks = await r.json();
  } catch {
    keep = false;
  }
  const marks = marksFromForks(forks);
  if (keep) try { sessionStorage.setItem(KEY, JSON.stringify({ at: Date.now(), marks })); } catch {}
  return marks;
}

Promise.resolve(cached() ?? fetchMarks()).then((marks) =>
  row.replaceChildren(...marks.map(({ name, handle }) => {
    const li = card.cloneNode(true);
    li.querySelector(".hand").textContent = name;
    li.querySelector(".handle").textContent = handle;
    return li;
  })));
