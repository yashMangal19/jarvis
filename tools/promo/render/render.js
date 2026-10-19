// The promo as a pure function of t (seconds): render(t) sets every frame from t alone. No clocks,
// no randomness, no CSS animation. BEATS is built from ../storyboard/beats.json and the sb-*.svg art.
const RED = '#C8302A';
const ease = u => (u <= 0 ? 0 : u >= 1 ? 1 : u * u * (3 - 2 * u));
const span = (u, a, b) => ease((u - a) / (b - a));
// Where each kind of mark is drawn within a beat (u = 0…1). The rest of the beat holds still.
const INK = [0, 0.35], WORDS = [0.3, 0.65], MARKER = [0.65, 0.8];
// Words the action reveals only after the red marker has done its work (beat 7: the page goes blank).
const AFTER_MARKER = new Set(['(nothing here)']);
const BEATS = [];

async function load(file) {
  const res = await fetch(`../storyboard/${file}`);
  if (!res.ok) throw new Error(`${file}: ${res.status}`);
  return res;
}

function textEl(spec) {
  const el = document.createElement('div');
  el.className = 'txt';
  el.textContent = spec.t;
  Object.assign(el.style, {
    left: `${spec.x}px`, top: `${spec.y}px`, color: spec.color,
    font: `${spec.font === 'Caveat' ? 700 : 400} ${spec.size}px "${spec.font}"`,
  });
  return el;
}

// Spreads n marks over [a, b], each overlapping the next a little.
const slots = (n, [a, b]) => Array.from({ length: n }, (_, i) => {
  const w = (b - a) / n;
  return [a + i * w, Math.min(b, a + (i + 1.6) * w)];
});

window.ready = (async () => {
  const stage = document.getElementById('stage');
  let start = 0;
  for (const beat of await (await load('beats.json')).json()) {
    const layer = document.createElement('div');
    layer.className = 'beat';
    layer.innerHTML = await (await load(`sb-${beat.key}.svg`)).text();
    layer.hidden = true;
    stage.append(layer);

    const paths = [...layer.querySelectorAll('path')].map(el => {
      const stroked = el.getAttribute('fill') === 'none';
      const len = stroked ? el.getTotalLength() : 0;
      if (stroked) el.style.strokeDasharray = `${len}`;
      return { el, stroked, len, red: el.getAttribute('stroke') === RED };
    });
    const ink = paths.filter(p => !p.red), marker = paths.filter(p => p.red);
    const words = beat.texts.filter(s => !s.rot && !AFTER_MARKER.has(s.t));
    const late = beat.texts.filter(s => s.rot || AFTER_MARKER.has(s.t));
    const marks = [
      ...ink.map((p, i) => ({ ...p, kind: 'path', at: slots(ink.length, INK)[i] })),
      ...words.map((s, i) => ({ el: layer.appendChild(textEl(s)), kind: s.font === 'Caveat' ? 'letter' : 'type', text: s.t, at: slots(words.length, WORDS)[i] })),
      ...marker.map((p, i) => ({ ...p, kind: 'path', at: slots(marker.length + late.length, MARKER)[i] })),
      ...late.map((s, i) => {
        const el = layer.appendChild(textEl(s));
        el.style.rotate = `${s.rot}deg`;
        return { el, kind: s.rot ? 'stamp' : 'fade', at: slots(marker.length + late.length, MARKER)[marker.length + i] };
      }),
    ];
    BEATS.push({ ...beat, start, end: start + beat.secs, layer, marks });
    start += beat.secs;
  }
  window.DURATION = start;
  // Text sits in hidden layers, which never trigger a font load on their own.
  await Promise.all([document.fonts.load('700 40px "Caveat"'), document.fonts.load('40px "Courier Prime"')]);
})();

function draw(mark, p) {
  const { el } = mark;
  if (mark.kind === 'path') {
    if (mark.stroked) el.style.strokeDashoffset = `${mark.len * (1 - p)}`;
    else el.style.opacity = `${p}`;
  } else if (mark.kind === 'type') {
    el.textContent = mark.text.slice(0, Math.round(p * mark.text.length));
  } else if (mark.kind === 'letter') {
    // Caveat's strokes overhang the text box, so the reveal ends 10% past both edges.
    el.style.clipPath = `inset(-50% ${110 * (1 - p) - 10}% -50% -10%)`;
  } else {
    el.style.opacity = `${p}`;
    if (mark.kind === 'stamp') el.style.scale = `${1.6 - 0.6 * p}`;
  }
}

window.render = t => {
  const beat = BEATS.find(b => t < b.end) ?? BEATS.at(-1);
  const u = (t - beat.start) / beat.secs;
  for (const b of BEATS) b.layer.hidden = b !== beat;
  for (const mark of beat.marks) draw(mark, span(u, ...mark.at));
  const caption = document.getElementById('caption');
  caption.textContent = beat.caption;
  caption.style.opacity = `${span(t - beat.start, 0, 0.3)}`;
};
