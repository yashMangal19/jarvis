// p. 8: copy buttons on the install strips. "copied" only after the clipboard accepted the line;
// otherwise the strip's text is selected so the visitor can copy it by hand.
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
