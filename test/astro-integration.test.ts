declare global {
  var __yukuAstroIntegration: { calls: number; css: number; scripts: number; scopes: string[] };
}
import type { AddressInfo } from "node:net";

// Build real Astro pages with only its transform import redirected to this compiler.
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { createRequire } from "node:module";
import { createServer } from "node:http";
import { assert, test } from "vite-plus/test";

test("Astro builds static pages and SSR with working React hydration and scoped CSS", async () => {
  process.env.ASTRO_TELEMETRY_DISABLED = "1";
  const { registerHooks } = await import("node:module");
  const installed = createRequire(import.meta.url);
  const directory = path.dirname(installed.resolve("astro/package.json"));
  const { default: react } = await import(pathToFileURL(installed.resolve("@astrojs/react")).href);
  const { default: node } = await import(pathToFileURL(installed.resolve("@astrojs/node")).href);
  fs.mkdirSync(".tmp", { recursive: true });
  const root = fs.mkdtempSync(path.resolve(".tmp/astro-integration-"));
  const fixture = path.resolve("test/fixtures/astro-integration");
  fs.cpSync(fixture, root, { recursive: true });
  fs.writeFileSync(
    path.join(root, "package.json"),
    JSON.stringify({
      name: "yuku-astro-integration",
      private: true,
      type: "module",
      dependencies: {
        astro: "7.4.0",
        "@astrojs/react": "7.1.0",
        react: "19.3.1",
        "react-dom": "19.3.1",
        "@astrojs/node": "11.1.8",
      },
    }),
  );
  const api = pathToFileURL(path.resolve("dist/index.mjs")).href;
  const bridge = path.join(root, "compiler.mjs");
  fs.writeFileSync(
    bridge,
    "import {transform as nativeTransform} from " +
      JSON.stringify(api) +
      ";\n" +
      "export function transform(source,options){const result=nativeTransform(source,options);" +
      "const stats=globalThis.__yukuAstroIntegration;stats.calls++;" +
      "stats.css+=result.css.length;stats.scripts+=result.scripts.length;" +
      "stats.scopes.push(result.scope);return result;}\n",
  );
  const stats = (globalThis.__yukuAstroIntegration = {
    calls: 0,
    css: 0,
    scripts: 0,
    scopes: [] as any[],
  });
  const redirected = new Set();
  const hooks = registerHooks({
    load(url, context, next) {
      const result = next(url, context);
      if (
        url.endsWith("/astro/dist/core/compile/compile.js") ||
        url.endsWith("/astro/dist/vite-plugin-environment/rolldown-plugin-astro-scan.js")
      ) {
        const original =
          typeof result.source === "string"
            ? result.source
            : Buffer.from(result.source as Uint8Array).toString();
        let source = original;
        const replacement =
          "import {transform} from " + JSON.stringify(pathToFileURL(bridge).href) + ";";
        source = source
          .replace(
            'import { preprocessStyles, transform } from "@astrojs/compiler-rs";',
            'import {preprocessStyles} from "@astrojs/compiler-rs";\n' + replacement,
          )
          .replace('import { transform } from "@astrojs/compiler-rs";', replacement);
        assert.notStrictEqual(source, original, "The Astro transform import must be redirected");
        redirected.add(url);
        return { ...result, source };
      }
      return result;
    },
  });
  try {
    const { build } = await import(pathToFileURL(path.join(directory, "dist/index.js")).href);
    await build({
      root: pathToFileURL(root + path.sep),
      configFile: false,
      logLevel: "error",
      devToolbar: { enabled: false },
      build: { inlineStylesheets: "never" },
      vite: { build: { assetsInlineLimit: 0 } },
      integrations: [react()],
    });
    assert.ok(redirected.size > 0);
    assert.ok(stats.calls >= 6, JSON.stringify(stats));
    assert.ok(stats.css >= 2);
    assert.ok(stats.scripts >= 1);
    const read = (route: string) =>
      fs.readFileSync(path.join(root, "dist", route, "index.html"), "utf8");
    const home = read("");
    assert.match(home, /<h1[^>]*>Yuku compiler integration<\/h1>/);
    assert.match(home, /<h2[^>]*>Named title<\/h2>/);
    assert.match(home, /<p[^>]*>Default body<\/p>/);
    assert.match(home, /data-astro-cid-/);
    assert.match(home, /_astro\/[^"]+\.css/);
    assert.match(home, /<script[^>]*src="[^"]+\.js"/);
    assert.match(home, /<astro-island[^>]*client="load"/);
    assert.match(home, />React count:.*4/);
    assert.match(read("items/alpha"), />Alpha:3</);
    assert.match(read("items/beta"), />Beta:3</);
    assert.match(read("slots"), /<strong[^>]*>Conditional title<\/strong>/);
    assert.match(read("raw"), /<em>trusted<\/em>/);
    assert.match(read("raw"), /&lt;script&gt;/);
    const assets = fs.readdirSync(path.join(root, "dist/_astro"));
    assert.ok(assets.some((file) => file.endsWith(".css")));
    assert.ok(assets.some((file) => file.endsWith(".js")));
    const scripts = assets
      .filter((file) => file.endsWith(".js"))
      .map((file) => fs.readFileSync(path.join(root, "dist/_astro", file), "utf8"))
      .join("\n");
    assert.match(scripts, /yuku-client-ready/);
    assert.match(scripts, /react\.transitional\.element/);
    const staticCalls = stats.calls;
    await build({
      root: pathToFileURL(root + path.sep),
      configFile: false,
      logLevel: "error",
      devToolbar: { enabled: false },
      output: "server",
      outDir: "./dist-server/",
      build: { inlineStylesheets: "never" },
      vite: { build: { assetsInlineLimit: 0 } },
      integrations: [react()],
      adapter: node({ mode: "middleware" }),
    });
    assert.ok(stats.calls > staticCalls, "The server build must also use native transform");
    const { handler } = await import(
      pathToFileURL(path.join(root, "dist-server/server/entry.mjs")).href
    );
    const server = createServer((request, response) => {
      const pathname = new URL(request.url ?? "/", "http://localhost").pathname;
      if (/^\/_astro\/[a-zA-Z0-9_.-]+$/.test(pathname)) {
        const file = path.join(root, "dist-server/client", pathname);
        if (fs.existsSync(file)) {
          response.setHeader(
            "content-type",
            pathname.endsWith(".css") ? "text/css" : "application/javascript",
          );
          response.end(fs.readFileSync(file));
          return;
        }
      }
      handler(request, response, () => {
        response.statusCode = 404;
        response.end("Not found");
      });
    });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", () => resolve());
    });
    let browserHydration = false;
    try {
      for (const [route, pattern] of [
        ["/", /Yuku compiler integration/],
        ["/slots", /Conditional title/],
        ["/raw", /<em>trusted<\/em>/],
      ] as [string, RegExp][]) {
        const response = await fetch(
          "http://127.0.0.1:" + (server.address() as AddressInfo).port + route,
        );
        assert.strictEqual(response.status, 200, route);
        assert.match(await response.text(), pattern, route);
      }
      {
        const { chromium } = installed("playwright-core");
        const browser = await chromium.launch({ headless: true });
        try {
          const page = await browser.newPage();
          const errors = [] as any[];
          page.on("pageerror", (error: any) =>
            errors.push(error instanceof Error ? error.message : String(error)),
          );
          await page.goto("http://127.0.0.1:" + (server.address() as AddressInfo).port + "/", {
            waitUntil: "networkidle",
          });
          await page.waitForFunction(
            () => !document.querySelector("astro-island")?.hasAttribute("ssr"),
          );
          const button = page.locator("#react-counter");
          assert.strictEqual(await button.textContent(), "React count:4");
          await button.click();
          await page.waitForFunction(
            () => document.querySelector("#react-counter")?.textContent === "React count:5",
          );
          assert.strictEqual(
            await page.locator("html").getAttribute("data-yuku"),
            "yuku-client-ready:3",
          );
          assert.strictEqual(
            await page
              .locator("article.card")
              .evaluate((element: any) => getComputedStyle(element).color),
            "rgb(255, 99, 71)",
          );
          assert.deepEqual(errors, [] as any[]);
          browserHydration = true;
        } finally {
          await browser.close();
        }
      }
    } finally {
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      );
    }
    assert.strictEqual(browserHydration, true);
  } finally {
    hooks.deregister();
    delete (globalThis as Partial<typeof globalThis>).__yukuAstroIntegration;
  }
}, 120_000);
