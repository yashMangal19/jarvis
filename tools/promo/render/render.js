// The promo as a pure function of t (seconds): render(t) sets every frame from t alone. No clocks,
// no randomness, no CSS animation. BEATS is built from ../storyboard/beats.json and the sb-*.svg art.
const RED = '#C8302A';
const ease = u => (u <= 0 ? 0 : u >= 1 ? 1 : u * u * (3 - 2 * u));
const span = (u, a, b) => ease((u - a) / (b - a));
// Where each kind of mark is drawn within a beat (u = 0…1). The rest of the beat holds still.
const INK = [0, 0.35], WORDS = [0.3, 0.65], MARKER = [0.65, 0.8];
// Every text is shrunk, never stretched, to fit: its `w`, else the filled art it sits on (keeping the same
// inset on the right as on the left), else the frame less this margin.
const MARGIN = 60;
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

// The smallest filled shape under the middle of a text's first line, in frame coordinates.
function artUnder(layer, spec) {
  const x = spec.x + 1, y = spec.y + spec.size / 2;
  let best = null;
  for (const el of layer.querySelectorAll('path:not([fill="none"])')) {
    const r = el.getBoundingClientRect();
    const inside = x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
    if (inside && (!best || r.width * r.height < best.width * best.height)) best = r;
  }
  return best;
}

function fit(el, spec, layer) {
  const art = spec.w ? null : artUnder(layer, spec);
  const right = spec.w ? spec.x + spec.w : Math.min(art ? art.right - (spec.x - art.left) : Infinity, 1920 - MARGIN);
  const width = el.getBoundingClientRect().width;
  if (width > right - spec.x) el.style.fontSize = `${(spec.size * (right - spec.x)) / width}px`;
}

function wordRects(el) {
  return [...el.textContent.matchAll(/\S+/g)].map(m => {
    const range = document.createRange();
    range.setStart(el.firstChild, m.index);
    range.setEnd(el.firstChild, m.index + m[0].length);
    return range.getBoundingClientRect();
  });
}

// A flat red line across a text is a strike. Note which words it crosses before the text is fitted, then
// stretch the line along x to span exactly those words once it is.
function strikes(layer, texts) {
  return [...layer.querySelectorAll(`path[stroke="${RED}"]`)].flatMap(path => {
    const r = path.getBoundingClientRect();
    if (r.height > 6) return [];
    for (const el of texts) {
      const box = el.getBoundingClientRect();
      if (r.top < box.top || r.top > box.bottom) continue;
      const words = wordRects(el).flatMap((w, i) => (w.right > r.left && w.left < r.right ? [i] : []));
      if (words.length) return [{ path, el, words, r }];
    }
    return [];
  });
}

function stretch({ path, el, words, r }) {
  const rects = wordRects(el), a = rects[words[0]].left, b = rects[words.at(-1)].right;
  const x0 = path.getBBox().x;
  path.setAttribute('transform', `translate(${x0 + a - r.left} 0) scale(${(b - a) / r.width} 1) translate(${-x0} 0)`);
}

// Spreads n marks over [a, b], each overlapping the next a little.
const slots = (n, [a, b]) => Array.from({ length: n }, (_, i) => {
  const w = (b - a) / n;
  return [a + i * w, Math.min(b, a + (i + 1.6) * w)];
});

window.ready = (async () => {
  // Text sits in hidden layers, which never trigger a font load on their own.
  await Promise.all([document.fonts.load('700 40px "Caveat"'), document.fonts.load('40px "Courier Prime"')]);
  const stage = document.getElementById('stage');
  let start = 0;
  for (const beat of await (await load('beats.json')).json()) {
    const layer = document.createElement('div');
    layer.className = 'beat';
    layer.innerHTML = await (await load(`sb-${beat.key}.svg`)).text();
    stage.append(layer);

    const paths = [...layer.querySelectorAll('path')].map(el => {
      const stroked = el.getAttribute('fill') === 'none';
      const len = stroked ? el.getTotalLength() : 0;
      if (stroked) el.style.strokeDasharray = `${len}`;
      return { el, stroked, len, red: el.getAttribute('stroke') === RED };
    });
    const els = new Map(beat.texts.map(s => [s, layer.appendChild(textEl(s))]));
    const struck = strikes(layer, [...els.values()]);
    for (const [s, el] of els) fit(el, s, layer);
    struck.forEach(stretch);
    layer.hidden = true;
    const ink = paths.filter(p => !p.red), marker = paths.filter(p => p.red);
    // Stamps, and words marked "after": "marker", land with the red marker, after the other words.
    const late = beat.texts.filter(s => s.rot || s.after === 'marker');
    const words = beat.texts.filter(s => !late.includes(s));
    const marks = [
      ...ink.map((p, i) => ({ ...p, kind: 'path', at: slots(ink.length, INK)[i] })),
      ...words.map((s, i) => ({ el: els.get(s), kind: s.font === 'Caveat' ? 'letter' : 'type', text: s.t, at: slots(words.length, WORDS)[i] })),
      ...marker.map((p, i) => ({ ...p, kind: 'path', at: slots(marker.length + late.length, MARKER)[i] })),
      ...late.map((s, i) => {
        const el = els.get(s);
        el.style.rotate = `${s.rot}deg`;
        return { el, kind: s.rot ? 'stamp' : 'fade', at: slots(marker.length + late.length, MARKER)[marker.length + i] };
      }),
    ];
    BEATS.push({ ...beat, start, end: start + beat.secs, layer, marks });
    start += beat.secs;
  }
  window.DURATION = start;
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
  caption.textContent = beat.caption ?? '';
  caption.style.opacity = `${span(t - beat.start, 0, 0.3)}`;
};
