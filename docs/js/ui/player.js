// p. 2: the taped "promo lands soon" card covers the player until the promo's metadata loads.
// A missing or broken promo never fires loadedmetadata, so the card stays on error with no handler.
// Styles are inline because site.css is out of this module's reach.
const player = document.querySelector('#p2 [data-slot="player"]');
const video = player.querySelector("video");

const card = document.createElement("div");
card.style.cssText = "position: absolute; inset: 0; background: #F4F1E8 url(assets/poster-placeholder.svg) 0 0 / 100% 100%;";
const label = document.createElement("p");
label.textContent = "promo lands soon";
label.style.cssText = "position: absolute; top: 12px; right: 16px; margin: 0; color: #2E2D2B; font-size: 13px; letter-spacing: .15em;";
card.append(label);
player.prepend(card); // first child, so the tapes still sit on top of it

const ready = () => { card.hidden = true; };
if (video.readyState >= HTMLMediaElement.HAVE_METADATA) ready();
else video.addEventListener("loadedmetadata", ready, { once: true });

// The real poster replaces the browser's blank frame only once it is known to load.
const poster = new Image();
poster.addEventListener("load", () => { video.poster = poster.src; });
poster.src = "media/poster.png";
