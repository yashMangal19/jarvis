// p. 2: the taped "promo lands soon" card covers the player until the promo's metadata loads.
// A missing or broken promo never fires loadedmetadata, so the card stays on error with no handler.
// Styles are inline because the blueprint's file list for this ticket has no stylesheet in it.
const player = document.querySelector('#p2 [data-slot="player"]');
const video = player.querySelector("video");

// The SVG already reads "promo lands soon"; the accessible name says it to screen readers.
const card = Object.assign(document.createElement("img"),
  { src: "assets/poster-placeholder.svg", alt: "promo lands soon" });
card.style.cssText = "position: absolute; inset: 0; width: 100%; height: 100%; background: var(--chalk);";
player.prepend(card); // first child, so the tapes and the "no sound" label still sit on top of it

const ready = () => { card.hidden = true; };
if (video.readyState >= HTMLMediaElement.HAVE_METADATA) ready();
else video.addEventListener("loadedmetadata", ready, { once: true });

// The real poster replaces the browser's blank frame only once it is known to load.
const poster = new Image();
poster.addEventListener("load", () => { video.poster = poster.src; });
poster.src = "media/poster.png";
