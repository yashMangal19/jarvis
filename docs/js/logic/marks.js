// GitHub forks list → "marks from forks" cards on p. 7. Pure: no DOM, no fetch.

// per_page=100 caps the count, so the "@you?" mark tops out at 101.
export const FORKS_URL =
  "https://api.github.com/repos/yashMangal19/jarvis/forks?sort=oldest&per_page=100";

// `forks` is the parsed API response; null or a non-array (a failed fetch) counts as none.
// Up to 5 fork cards in API order, then the visitor's card: the mark their fork would really get.
export function marksFromForks(forks) {
  const list = Array.isArray(forks) ? forks : [];
  const cards = list.slice(0, 5).map((f, i) => mark(i + 1, `@${f.owner.login}`));
  return [...cards, mark(list.length + 1, "@you?")];
}

// The card shows name and handle on two lines; label is the same mark as one line.
const mark = (n, handle) => ({ label: `mark ${n} · ${handle}`, name: `mark ${n}`, handle });
