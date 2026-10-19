// The five suit-up plates and the status line computed from one tick per plate. Pure: no DOM.

// tagline heads each card; note is the typed sub-line under each option (copy from D4/M4 where shown).
const OWN = { id: "own", label: "your own", note: "bring your own model or tool.", needsInternet: false };
const row = (id, label, note, needsInternet = false) => ({ id, label, note, needsInternet });

export const PLATES = [
  { id: "ears", name: "ears", tagline: "hears the room.", defaultId: "any-mic", options: [
    row("any-mic", "any mic or airpods", "whatever you talk into."),
    row("built-in-mic", "built-in mic (meeting mode)", "hears everyone in the room."),
    row("call-audio", "call audio", "both sides of the call."),
    row("voice-memos", "voice memos", "recordings you already have."),
    OWN] },
  { id: "transcriber", name: "transcriber", tagline: "turns it into words.", defaultId: "whisper-cpp", options: [
    row("whisper-cpp", "whisper.cpp", "runs on your mac. offline."),
    row("speechanalyzer", "apple speechanalyzer", "built into macos. offline."),
    OWN] },
  { id: "notes", name: "notes", tagline: "writes the hour down.", defaultId: "claude", options: [
    row("claude", "claude", "smartest. needs the internet.", true),
    row("foundation-models", "apple foundation models", "built into macos. offline."),
    row("ollama", "ollama", "runs on your mac. offline."),
    OWN] },
  { id: "memory", name: "memory", tagline: "keeps it, finds it.", defaultId: "naturallanguage", options: [
    row("naturallanguage", "naturallanguage", "built into macos. offline."),
    row("contextual", "apple contextual", "built into macos. offline."),
    row("core-ai", "core ai", "runs on your mac. offline."),
    OWN] },
  { id: "hands", name: "hands", tagline: "does things for you. always asks first.", defaultId: "claude", options: [
    row("claude", "claude", "smartest. needs the internet.", true),
    OWN] },
];

export const defaultTicks = () => Object.fromEntries(PLATES.map((p) => [p.id, p.defaultId]));

// An unknown plate or option id falls back to the plate's default, so a bad tick never throws.
function needs(ticks, plateId) {
  const plate = PLATES.find((p) => p.id === plateId);
  const option = plate.options.find((o) => o.id === ticks?.[plateId])
    ?? plate.options.find((o) => o.id === plate.defaultId);
  return option.needsInternet;
}

export function offlineLine(ticks) {
  const n = needs(ticks, "notes");
  const h = needs(ticks, "hands");
  if (n && h) return "notes and commands still need the internet";
  if (n) return "notes still need the internet";
  if (h) return "commands still need the internet";
  return "now it runs fully offline";
}
