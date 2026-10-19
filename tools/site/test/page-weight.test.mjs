import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, statSync } from "node:fs";
import { join, sep } from "node:path";
import { fileURLToPath } from "node:url";

// User story 41: each PNG ≤ 200 KB, the page ≤ 1.5 MB before the video.
export const PNG_MAX = 200_000;
export const TOTAL_MAX = 1_500_000;

const DOCS = fileURLToPath(new URL("../../../docs/", import.meta.url));

// Served bytes under docs/, minus the video folder and the separate guide page.
function overweight(root, limits) {
  const files = readdirSync(root, { recursive: true })
    .map((rel) => ({ rel: rel.split(sep).join("/"), stat: statSync(join(root, rel)) }))
    .filter(({ rel, stat }) => stat.isFile() && !rel.startsWith("media/") && rel !== "guide.html")
    .map(({ rel, stat }) => ({ rel, bytes: stat.size }));
  const pngs = files.filter((f) => f.rel.endsWith(".png"));
  const report = {
    png: Math.max(0, ...pngs.map((f) => f.bytes)),
    total: files.reduce((sum, f) => sum + f.bytes, 0),
  };
  const problems = [
    ...pngs.filter((f) => f.bytes > limits.png).map((f) => `${f.rel} is ${f.bytes} B > ${limits.png} B`),
    ...(report.total > limits.total ? [`docs/ totals ${report.total} B > ${limits.total} B`] : []),
  ];
  return { report, problems };
}

test("docs/ is within the page-weight limits", () => {
  const { report, problems } = overweight(DOCS, { png: PNG_MAX, total: TOTAL_MAX });
  assert.deepEqual(problems, [], `largest png ${report.png} B, total ${report.total} B\n${problems.join("\n")}`);
});

for (const shrink of ["png", "total"]) {
  test(`shrinking the ${shrink} limit below what docs/ weighs fails the check`, () => {
    const { report } = overweight(DOCS, { png: PNG_MAX, total: TOTAL_MAX });
    const limits = { png: PNG_MAX, total: TOTAL_MAX, [shrink]: report[shrink] - 1 };
    assert.notDeepEqual(overweight(DOCS, limits).problems, []);
  });
}
