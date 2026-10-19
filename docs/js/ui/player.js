// p. 2: the taped "promo lands soon" card covers the player until the promo's metadata loads.
// A missing or broken promo never fires loadedmetadata, so the card stays on error with no handler.
const player = document.querySelector('#p2 [data-slot="player"]');
const video = player.querySelector("video");

// The SVG already reads "promo lands soon"; the accessible name says it to screen readers.
const card = Object.assign(document.createElement("img"),
  { src: "assets/poster-placeholder.svg", alt: "promo lands soon" });
card.style.cssText = "position: absolute; inset: 0; width: 100%; height: 100%; background: var(--chalk);";
player.prepend(card); // first child, so the tapes and the "no sound" label still sit on top of it

// Before the first play the frame stays clean: no native control bar over the poster, one big play button.
// The markup keeps `controls`, so with no script the video still plays. Nothing ever plays by itself.
video.controls = false;
const play = Object.assign(document.createElement("button"), { type: "button", className: "play", hidden: true });
play.setAttribute("aria-label", "play the promo");
play.innerHTML = '<svg viewBox="0 0 100 100" aria-hidden="true" focusable="false">'
  + '<path class="ring" d="M50,4 C76,3 97,23 96,50 C95,77 75,97 49,96 C23,95 4,76 5,49 C6,24 25,5 52,5"/>'
  + '<path class="tri" d="M38,29 L39,72 L74,50 Z"/></svg>';
player.append(play);
play.addEventListener("click", () => video.play().catch(() => {})); // a refused play leaves the frame as it was
video.addEventListener("play", () => { video.controls = true; play.hidden = true; }, { once: true });
// While it plays, the "no sound" tag steps aside (it sits on the picture); paused or ended, it is back.
video.addEventListener("play", () => { player.dataset.playing = ""; });
for (const stop of ["pause", "ended"]) video.addEventListener(stop, () => { delete player.dataset.playing; });

const ready = () => { card.hidden = true; play.hidden = !video.paused; };
if (video.readyState >= HTMLMediaElement.HAVE_METADATA) ready();
else video.addEventListener("loadedmetadata", ready, { once: true });

// The real poster replaces the browser's blank frame only once it is known to load.
const poster = new Image();
poster.addEventListener("load", () => { video.poster = poster.src; });
poster.src = "media/poster.png";
