import { defineConfig } from "@playwright/test";

const PORT = 4173;

export default defineConfig({
  testDir: "smoke",
  testMatch: "*.spec.mjs",
  webServer: {
    command: `node smoke/serve.mjs --port ${PORT}`,
    url: `http://127.0.0.1:${PORT}/`,
    reuseExistingServer: !process.env.CI,
  },
  use: { baseURL: `http://127.0.0.1:${PORT}`, channel: "chrome" },
  projects: [
    { name: "desktop", use: { viewport: { width: 1440, height: 900 } } },
    { name: "phone", use: { viewport: { width: 390, height: 844 } } },
  ],
});
