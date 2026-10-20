# jarvis-site: promo site, live status and promo video

Shipped in PR #1 (`51914d6`, site and status pipeline) and PR #2 (`e28d472`, promo media and UI fixes).
Live at <https://yashmangal19.github.io/jarvis/>. Run artifacts: `~/jarvis/.agentic/jarvis-site/`
(spec, blueprint, tickets, grill log, QA cases, visual QA sweeps).

## Final architecture

Three modules, with no build step and no npm in the served tree.

- **`docs/`, the served site.** One page with eight numbered sketchbook pages (`#p1`…`#p8`), plain HTML,
  CSS and ES modules. `docs/guide.html` is still served and linked from p. 8 and the footer.
  - `js/logic/*`: pure and DOM-free, tested with `node --test`. `status.js` holds parse, freshness,
    `liveLine` and `ageLabel`. `launch.js` is the launch state machine (countdown, online, late,
    late-unknown) with a hard-coded deadline of `2026-10-19T21:00:00+05:30`. `plates.js` holds the
    plates and the offline line. `marks.js` turns forks into hall marks.
  - `js/status-feed.js` fetches `raw.githubusercontent.com/yashMangal19/jarvis/status/status.json` on
    load and every 5 min (20 s abort). It keeps the last good copy and sends it to subscribers.
  - `js/ui/*`: one renderer per page area, all imported once by `js/main.js`. CSS is split into
    `site.css` plus `hero.css`, `suit-up.css` and `try-it.css`. The page writes into `data-slot`
    elements, so a ticket never targets page structure.
  - `js/ui/motion.js` loads GSAP 3.15.0 and ScrollTrigger from cdnjs with SRI, only when reduced motion
    is off. The page works without them.
  - `media/`: `promo.mp4` (45 s, 1080p, silent), `promo.gif` (10 s) and `poster.png`.
- **`tools/site/`: the status job and the tests.** `status/compute.mjs` builds status.json (schema 1)
  from `~/jarvis/.agentic/jarvis-ambient-memory` (run.json, tickets output, progress.jsonl, QA cases
  and results). It also reads git facts from a blobless cache (`collect-git.mjs`: five newest commits,
  and whether `v0.1.0` exists on origin) and `~/jarvis/.agentic/jarvis-site/launch-note.md`.
  `status/publish.mjs` commits that one file to the orphan `status` branch. It never forces a push and
  skips the push when nothing changed and the file is under 1 h old.
  The LaunchAgent `in.jarvis.site-status` runs the job hourly and unloads itself after it publishes
  `shipped: true`. Playwright smoke tests live in `smoke/`. `tools/site/README.md` is the runbook.
- **`tools/promo/`: the promo video.** `render/` is a deterministic `render(t)` page that builds its
  beats from `storyboard/beats.json` and the `sb-*.svg` art. `capture.mjs` (puppeteer-core with local
  Chrome) writes 1350 frames. `encode.mjs` (ffmpeg) writes the MP4, the GIF (from a fixed `GIF_CUT`)
  and the poster into `docs/media/`.

Outside this repo: the README promo block (GIF, site link and brew line) is commit `7a116c0` on
`feature/jarvis-ambient-memory`. It is not on this repo's `main`; it arrives when that branch merges.

## Files changed

- `docs/`: `index.html` rewritten, plus `css/`, `js/`, `assets/` (art, busy, texture) and `media/`.
- `tools/site/`: `status/` (job and plist), `test/` (node:test with fixtures), `smoke/` (10 Playwright
  specs, `serve.mjs`, and the `test.mjs` CDN fixture), and the README.
- `tools/promo/`: `render/`, `storyboard/`, `capture.mjs`, `encode.mjs` and `test/`.

## Implementation flow

Hourly job → `status` branch → page fetch → `parseStatus` (an unknown schema is treated as missing) →
subscribers: `launchState(now, s)` drives the hero through one `data-state` attribute, `live-build.js`
fills p. 3, and `fork-it.js` shows the brew strip. The forks API is called once per visit and fills
the hall, with an "@you?" card always last. Promo: beats.json → render(t) → frames → ffmpeg → `docs/media/`.

## Important decisions

- The status branch is an orphan on the public repo (D-4). Keep it while the page is up: once shipped,
  the last file holds the final numbers.
- The plist runs `~/jarvis-site-wt/tools/site/status/publish.mjs`. Removing that worktree breaks the
  agent, so unload the agent first.
- `qa.total` counts only the spec-moment cases in ambient-memory's `cases.yaml` (88). Cases with a
  per-case `moment: ticket` are excluded.
- `shipped` means the `v0.1.0` tag exists on origin. `shipped_at` is the tag's commit date.
- D-1: T-8 created every UI module and area stylesheet as a stub and linked each once, so wave 5 could
  run in parallel. That layout is final.
- Design overrides, where the spec beat the frames: the hero callout is on the notes plate; no ollama
  under hands; hand checks are out of 88, not 29, with no "(start sunday)"; the player is labelled
  "no sound" and titled "the 45-second version"; five commits are shown; p. 8 has the brew strip and the
  longer footer; "@you?" is always the last mark.

## Deviations from the approved blueprint

| # | Blueprint said | What landed | Explained? |
|---|---|---|---|
| 1 | Tickets T-1…T-19 only | UI-1…UI-6, six fix tickets with no blueprint section, after visual QA found 27 bugs on the first live release (4 high, 13 medium, 10 low). The visual QA had missed that release. Four sweeps followed; UI-6 fixed 8 new bugs at 1024 px. | Yes: run.json `tickets[].source`, grill-log (visual QA entries), `qa/visual-qa-1..4.md` |
| 2 | T-16 runs in the main session: Figma page, `frame-{1..7}.png`, `STORYBOARD.md` | Jarvis-Content and Jarvis-Design made it (Orc D1). It is committed as `storyboard/beats.json` plus 10 SVG frames (beats 1–9, with 6a/6b). | Yes: grill-log "T-16 storyboard moved…" |
| 3 | T-17: `BEATS` is a hand-made constant from STORYBOARD.md | Built at runtime from `beats.json`. Our copy of beats.json has small position and caption edits; the designer's original is untouched. | Yes: grill-log, T-17 report |
| 4 | T-18: GIF is the first 10 s of the MP4; poster is the middle of the last beat | The GIF comes from Content's 10 s cut (`GIF_CUT`) and reads the PNG frames, with fps applied per segment. Beat 9 enters at 43 s (the user's call). The poster is the last frame. | Yes: grill-log, T-18 report |
| 5 | T-4 returns strings | Returns `[{label}]` objects (the ticket won). UI-4 added name and handle to the data. | Yes: grill-log |
| 6 | T-5 fetches `main` and the feature branch | Fetches every origin branch with `--prune`, so a deleted branch can't block `shipped: true`. Cases with `moment: ticket` are excluded from QA counts. | Yes: grill-log, T-5 report |
| 7 | T-14: brew strip always on p. 8 | Hidden until `release.shipped`, because the tap installs from the v0.1.0 tarball. p. 8 is shorter until release. | Yes: grill-log, T-14 report |
| 8 | T-15: `clearProps: "all"`; the placeholder hides on `loadedmetadata` | A comma list (`all` wiped `--x`/`--y`). `motion.js` injects the turned-card style. The placeholder is an `<img>` over the video. A `smoke/test.mjs` fixture blocks cdnjs in every spec. | Yes: grill-log, T-15 report |
| 9 | T-8: one phone breakpoint at 600 px | Fluid layout: p. 1–3 stack at ≤960 px, and p. 4 stacks at ≤1100 px (UI-2). | Yes: T-8 review F-1, UI-2 report |
| 10 | T-11 uses `a-gauge.svg` | Replaced by `a-gauge-dial.svg` (no drawn needle). `#p1 .countdown` reserves 240 px. | Yes: grill-log, T-11 report |
| 11 | T-9: phone hall follows M7's swipe row | 2×2 grid. | Yes: grill-log, T-9 report |
| 12 | T-7 ships the art the pages use | `b-exploded.svg`, `circle.svg` and `waves.svg` are referenced nowhere. `arrow-curve.svg` is unused too, and UI-6 left it in place. | Partly: `waves.svg` (T-7 report) and `arrow-curve.svg` (UI-6 report). `b-exploded` and `circle` are unexplained. |
| 13 | One commit per ticket | `55f73bc` (UI-4) also holds UI-1's CSS hunks. `3650710` (UI-3) holds part of UI-2's p. 4 work. History was not rewritten. | Yes: grill-log, UI-1 and UI-4 reports |

Accepted trade-offs, from visual QA. Don't re-litigate these:
- The countdown pads single digits.
- The gauge is about 243 px, against about 265 px in D1.
- The p. 4 checkbox tick doesn't overshoot its box.
- p. 7 reserves space for 6 marks.
- The p. 4 open label sits just outside its ring.
- Short p. 4 cards leave plain paper above the "other plates" row.
- On phones and tablets, p. 5's closing line moves when the pricing answer shows.
- Native video controls briefly cover the burned-in caption.
- The first 403 from the forks API logs a line in the browser console.

## Experiment behaviour

There is no experiment flag. The nearest thing is the set of status-driven states: with no status.json
the page shows "status offline" and dashed boxes; a file over 2 h old adds "last update N h ago" on
p. 3; after the deadline the page is late (with a reason from `note_kind` or the QA numbers) until
`release.shipped`; after shipping it shows ONLINE with "shipped N h early/late" and the brew strip.

## Testing performed

- `tools/site` `node --test`: 102 passed.
- Playwright smoke at `--workers=4`: 291 passed, 113 skipped. The skips are viewport-only.
- `tools/promo`: 16 of 16 passed.
- Four manual visual QA sweeps (`qa/visual-qa-1..4.md`). After UI-6, none is open apart from the
  accepted trade-offs above.
- The pipeline was checked live: the first status push (`f14eba3`) showed the real numbers on Pages.

## QA coverage

302 cases written (135 at spec, 167 per ticket for T-8…T-15) · 0 existing TC ids reused (the coverage
scan never ran: `coverage_checked: false`) · 0 acceptance lines left untestable (11 raised at the spec
gate, all answered in spec.md). Export: `.agentic/jarvis-site/qa/export.md`. The promo and UI tickets
have no per-ticket cases.

## Remaining cleanup

- Delete the unused art: `docs/assets/art/{arrow-curve,b-exploded,circle,waves}.svg` (~72 KB, counted
  by the page-weight test).
- Full-parallel Playwright runs flake when the host is busy. Use `--workers=4`, and check that
  `lsof -ti tcp:4173` is empty first: `reuseExistingServer` will serve another checkout's `docs/`.
- `node --test` in `tools/site` also picks up `smoke/test.mjs` (Node's default `**/test.mjs` glob). It
  fails with `ERR_MODULE_NOT_FOUND` unless `npm ci` has run. Rename it, or pass an explicit test glob.
- The brew line in the README block (`7a116c0`) doesn't work until v0.1.0 is tagged and the tap
  formula is published. The site hides its own brew strip until then; the README can't.
- After shipping, the agent unloads, but the copy in `~/Library/LaunchAgents` reloads it at the next
  login. Delete it. Only then remove `~/jarvis-site-wt` (`tools/site/README.md`).
- The deadline is hard-coded. Until `v0.1.0` exists on origin, the hero stays in the late state.
- The "@you?" mark number tops out at 101 (`per_page=100` on the forks call).
