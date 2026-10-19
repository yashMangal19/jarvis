import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";

const SERVE = fileURLToPath(new URL("../smoke/serve.mjs", import.meta.url));

test("a malformed URL gets a 404 and the server keeps serving", async (t) => {
  const port = 4300 + Math.floor(Math.random() * 500);
  const child = spawn(process.execPath, [SERVE, "--port", String(port)], { stdio: ["ignore", "pipe", "ignore"] });
  t.after(() => child.kill());
  await once(child.stdout, "data");
  const bad = await fetch(`http://127.0.0.1:${port}/%E0%A4%A`);
  assert.equal(bad.status, 404);
  const home = await fetch(`http://127.0.0.1:${port}/`);
  assert.equal(home.status, 200);
});
