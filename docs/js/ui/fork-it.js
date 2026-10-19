// p. 8: copy buttons on the install strips. "copied" only after the clipboard accepted the line;
// otherwise the strip's text is selected so the visitor can copy it by hand.
import { subscribe } from "../status-feed.js";

// The tap's formula installs from the release tarball, so the brew line waits until it has shipped.
const brew = document.querySelector('#p8 [data-slot="brew-strip"]');
subscribe((s) => { brew.hidden = s?.release.shipped !== true; });

document.addEventListener("click", (e) => {
  const button = e.target.closest("[data-copy]");
  if (!button) return;
  const selectStrip = () => {
    const range = document.createRange();
    range.selectNodeContents(button.closest(".strip").querySelector("code"));
    getSelection().removeAllRanges();
    getSelection().addRange(range);
  };
  if (!navigator.clipboard) return selectStrip();
  navigator.clipboard.writeText(button.dataset.copy).then(() => {
    button.textContent = "copied";
    setTimeout(() => { button.textContent = "copy"; }, 2000);
  }, selectStrip);
});
