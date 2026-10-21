import { parse as parseRust } from "@astrojs/compiler-rs";
import rustPackage from "@astrojs/compiler-rs/package.json" with { type: "json" };
import { readFileSync } from "node:fs";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { assert } from "vite-plus/test";
import { Bench } from "tinybench";
import { parse as parseZig } from "../dist/index.mjs";

const { values, positionals } = parseArgs({
  options: {
    help: { type: "boolean" },
    time: { type: "string", default: "1000" },
    warmup: { type: "string", default: "500" },
  },
  allowPositionals: true,
});
if (values.help) {
  console.log("Usage: vp run bench [--time ms] [--warmup ms] [file.astro | inputs.json ...]");
  process.exit(0);
}
const time = Number(values.time);
const warmupTime = Number(values.warmup);
if (!Number.isFinite(time) || time <= 0) throw Error("--time must be positive milliseconds");
if (!Number.isFinite(warmupTime) || warmupTime < 0)
  throw Error("--warmup must be non-negative milliseconds");

interface Input {
  name: string;
  source: string;
}

function readInputs(file: string): Input[] {
  const source = readFileSync(file, "utf8");
  if (!file.endsWith(".json")) return [{ name: basename(file), source }];
  const inputs: unknown = JSON.parse(source);
  if (
    !Array.isArray(inputs) ||
    !inputs.length ||
    !inputs.every(
      (input) => input && typeof input.name === "string" && typeof input.source === "string",
    )
  )
    throw Error(`${file}: expected a non-empty array of { name, source }`);
  return inputs;
}

const files = positionals.length
  ? positionals
  : [fileURLToPath(new URL("../test/fixtures/bench/blume/_FeatureBrowser.astro", import.meta.url))];
const inputs = files.flatMap(readInputs);

// Validate the complete public AST before timing either parser.
for (const { name, source } of inputs) {
  const zig = parseZig(source);
  const rust = parseRust(source);
  assert.deepEqual(zig.ast, rust.ast, name + ": parsers return different ASTs");
  const hasError = (diagnostics: { severity: string }[]) =>
    diagnostics.some(({ severity }) => severity === "error");
  if (hasError(zig.diagnostics) !== hasError(rust.diagnostics))
    throw Error(`${name}: parsers disagree on syntax acceptance`);
}

console.log(`\nparse · astro-compiler-zig vs @astrojs/compiler-rs ${rustPackage.version}`);
console.log(`Node ${process.version} · ${time} ms per parser · ${warmupTime} ms warmup`);
for (const { name, source } of inputs) {
  console.log(`\n${name} · ${(Buffer.byteLength(source) / 1024).toFixed(1)} KiB`);
  let result: unknown;
  const bench = new Bench({
    time,
    iterations: 1,
    warmup: warmupTime > 0,
    warmupTime,
    warmupIterations: 1,
    timestampProvider: "hrtimeNow",
    throws: true,
  });
  const hooks = {
    async: false,
    beforeAll: () => {
      result = undefined;
      global.gc?.();
    },
  };
  bench.add(
    "astro-compiler-zig",
    () => {
      result = parseZig(source);
    },
    hooks,
  );
  bench.add(
    "@astrojs/compiler-rs",
    () => {
      result = parseRust(source);
    },
    hooks,
  );
  bench.runSync();
  console.table(
    bench.table((task) => {
      if (task.result.state !== "completed") throw Error(`${task.name}: ${task.result.state}`);
      const { latency, throughput } = task.result;
      return {
        Parser: task.name,
        "Mean (µs)": `${(latency.mean * 1000).toFixed(2)} ± ${latency.rme.toFixed(2)}%`,
        "Median (µs)": (latency.p50 * 1000).toFixed(2),
        "Parses/sec": Math.round(throughput.mean).toLocaleString("en-US"),
        Samples: latency.samplesCount,
      };
    }),
  );
  if (!result) throw Error("Parser did not return a result");
}
