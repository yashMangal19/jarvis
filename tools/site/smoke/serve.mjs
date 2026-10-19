// Dev-only static server over docs/ for the Playwright smoke. Usage: node smoke/serve.mjs --port 4173
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const ROOT = fileURLToPath(new URL("../../../docs/", import.meta.url));
const TYPES = {
  ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8", ".svg": "image/svg+xml", ".png": "image/png",
  ".mp4": "video/mp4",
};
const { port } = parseArgs({ options: { port: { type: "string", default: "4173" } } }).values;

createServer(async (req, res) => {
  try {
    const path = decodeURIComponent(new URL(req.url, "http://x").pathname);
    const file = normalize(join(ROOT, path.endsWith("/") ? path + "index.html" : path));
    if (!file.startsWith(ROOT) && file + sep !== ROOT) throw new Error("outside docs/");
    const body = await readFile(file);
    res.writeHead(200, { "content-type": TYPES[extname(file)] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found");
  }
}).listen(Number(port), "127.0.0.1", () => console.log(`serving docs/ on http://127.0.0.1:${port}`));
