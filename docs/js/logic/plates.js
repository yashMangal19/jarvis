// The five suit-up plates and the status line computed from one tick per plate. Pure: no DOM.

const OWN = { id: "own", label: "your own — bring your own model or tool", needsInternet: false };
const row = (id, label, needsInternet = false) => ({ id, label, needsInternet });

export const PLATES = [
  { id: "ears", name: "ears", defaultId: "any-mic", options: [
    row("any-mic", "any mic or airpods"),
    row("built-in-mic", "built-in mic (meeting mode)"),
    row("call-audio", "call audio"),
    row("voice-memos", "voice memos"),
    OWN] },
  { id: "transcriber", name: "transcriber", defaultId: "whisper-cpp", options: [
    row("whisper-cpp", "whisper.cpp"),
    row("speechanalyzer", "apple speechanalyzer"),
    OWN] },
  { id: "notes", name: "notes", defaultId: "claude", options: [
    row("claude", "claude", true),
    row("foundation-models", "apple foundation models"),
    row("ollama", "ollama"),
    OWN] },
  { id: "memory", name: "memory", defaultId: "naturallanguage", options: [
    row("naturallanguage", "naturallanguage"),
    row("contextual", "apple contextual"),
    row("core-ai", "core ai"),
    OWN] },
  { id: "hands", name: "hands", defaultId: "claude", options: [
    row("claude", "claude", true),
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
