// Optional motion: p. 2's flip-book turns as the page scrolls past, p. 4's plates fly in once.
// Never loads GSAP under reduced motion. If the CDN fails or is blocked, the page stays as it is.
// Not awaited at top level: main.js imports this module, and the page must not wait on a CDN.
const CDN = "https://cdnjs.cloudflare.com/ajax/libs/gsap/3.15.0/";

const load = (file, integrity) => new Promise((resolve, reject) => {
  const script = Object.assign(document.createElement("script"),
    { src: CDN + file, integrity, crossOrigin: "anonymous", onload: resolve, onerror: reject });
  document.head.append(script);
});

function flip(cards) {
  // Inline because site.css is out of this module's reach: a turned card lifts off the stack.
  const style = document.createElement("style");
  style.textContent = ".cards li { transition: translate .2s ease-out; } .cards li.is-turned { translate: 0 -20px; }";
  document.head.append(style);
  ScrollTrigger.create({
    trigger: "#p2", start: "top bottom", end: "bottom top",
    onUpdate: ({ progress }) => {
      const at = Math.floor(progress * cards.length);
      cards.forEach((card, i) => card.classList.toggle("is-turned", i <= at));
    },
  });
}

function flyIn(plates) {
  // Each plate starts further out along the line from the core, then settles into place.
  const core = plates[0].parentElement.getBoundingClientRect();
  const away = (el, axis) => {
    const b = el.getBoundingClientRect();
    return axis === "x" ? (b.left + b.width / 2 - core.left - core.width / 2) * 0.8
      : (b.top + b.height / 2 - core.top - core.height / 2) * 0.8;
  };
  ScrollTrigger.create({
    trigger: "#p4", once: true,
    onEnter: () => {
      gsap.set(plates, { transition: "none" }); // T-12's transform transition would smear each frame
      // Clear only what the tween set: "all" would also wipe each plate's inline --x/--y.
      gsap.from(plates, {
        x: (i, el) => away(el, "x"), y: (i, el) => away(el, "y"), opacity: 0,
        stagger: 0.08, clearProps: "transform,opacity,transition",
      });
    },
  });
}

if (!matchMedia("(prefers-reduced-motion: reduce)").matches) {
  load("gsap.min.js", "sha384-XmJ9SoHtVOHoQUcKvFAzVXwdkKo1Ie3bhmSoIAkcdsHGaIrVJIkmozyq0FJeb/Ly")
    .then(() => load("ScrollTrigger.min.js", "sha384-wl5TeDVvOWt30Pbf8aSo2ZrzsOjddu3avOBvHe+p+OhJt9gP6w9YXmDkN5DK2/dF"))
    .then(() => {
      gsap.registerPlugin(ScrollTrigger);
      flip([...document.querySelectorAll("#p2 .cards li")]);
      flyIn([...document.querySelectorAll('#p4 [data-slot="plate"]')]);
    })
    .catch(() => {}); // no motion is the fallback; nothing else on the page depends on it
}
