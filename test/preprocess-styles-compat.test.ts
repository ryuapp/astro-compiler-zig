import { assert, test } from "vite-plus/test";
import { preprocessStyles as reference } from "@astrojs/compiler-rs";
import { preprocessStyles } from "../dist/index.mjs";
import { preprocessStyles as esmPreprocessStyles } from "../dist/index.mjs";

type Setup = () => { args: unknown[]; events: string[] };
const styleSource = "<style>a</style><style>b</style>";

async function observe(api: unknown, setup: Setup) {
  const { args, events } = setup();
  let asynchronous = false;
  let before: string[] = [];
  try {
    const result: unknown = Reflect.apply(api as (...args: unknown[]) => unknown, undefined, args);
    asynchronous = result instanceof Promise;
    before = [...events];
    return { asynchronous, before, events, result: await result };
  } catch (error) {
    return {
      asynchronous,
      before,
      events,
      error:
        error instanceof Error
          ? { name: error.name, message: error.message, code: Reflect.get(error, "code") }
          : error,
    };
  }
}

const scenarios: { name: string; setup: Setup }[] = [];
for (const source of [
  "",
  "<p/>",
  "<style is:inline>p{}</style>",
  "<p>{bad + }</p><style>x</style>",
  styleSource,
]) {
  for (const callback of [undefined, null, 42, {}, [], Symbol("callback")]) {
    scenarios.push({
      name: `non-callable ${typeof callback} with ${JSON.stringify(source)}`,
      setup: () => ({ args: [source, callback], events: [] }),
    });
  }
}

const inputs = [
  undefined,
  null,
  42,
  NaN,
  Infinity,
  -Infinity,
  -0,
  1e30,
  true,
  false,
  1n,
  Symbol("source"),
  {},
  [],
  [1, "x"],
  new String("<style/>"),
  new Date(0),
  new Set([1]),
  new Map([[1, 2]]),
  Buffer.from("<style/>"),
  function namedSource() {},
  () => {},
];
for (const [index, source] of inputs.entries())
  scenarios.push({
    name: `invalid source ${index}`,
    setup: () => ({ args: [source, () => null], events: [] }),
  });

for (const [index, name] of [undefined, null, "", 42, {}, Symbol("name"), "custom"].entries())
  scenarios.push({
    name: "invalid function source name: " + index,
    setup: () => {
      const events: string[] = [];
      const source = () => {};
      Object.defineProperty(source, "name", {
        get() {
          events.push("get name");
          return name;
        },
      });
      return { args: [source, () => null], events };
    },
  });

for (const kind of ["undefined", "null", "bigint", "throw", "cycle"] as const)
  scenarios.push({
    name: "invalid object source serialization: " + kind,
    setup: () => {
      const events: string[] = [];
      const source: { toJSON?(): unknown; self?: unknown } = {};
      if (kind === "cycle") source.self = source;
      else
        source.toJSON = () => {
          events.push("toJSON");
          if (kind === "throw") throw new Error("serialization failed");
          return kind === "undefined" ? undefined : kind === "null" ? null : 1n;
        };
      return { args: [source, () => null], events };
    },
  });

for (const asynchronous of [false, true]) {
  for (const behavior of ["code", "error", "then-throws", "has-throws", "code-throws"] as const) {
    scenarios.push({
      name: `result property access: ${behavior}, async=${asynchronous}`,
      setup: () => {
        const events: string[] = [];
        const callback = (content: string) => {
          events.push("callback " + content);
          const value = new Proxy(
            {},
            {
              has(_target, name) {
                events.push(content + " has " + String(name));
                if (behavior === "has-throws") throw new Error("has failed");
                return name === "error" && behavior === "error";
              },
              get(_target, name) {
                events.push(content + " get " + String(name));
                if (name === "then" && behavior === "then-throws") throw new Error("then failed");
                if (name === "error") return "error from " + content;
                if (name === "code") {
                  if (behavior === "code-throws") throw new Error("code failed");
                  return "processed " + content;
                }
                return undefined;
              },
            },
          );
          return asynchronous ? Promise.resolve(value) : value;
        };
        return { args: [styleSource, callback], events };
      },
    });
  }
}

for (const value of [true, false, 0, 42, "text", Symbol("result"), 1n, null, undefined]) {
  for (const asynchronous of [false, true]) {
    scenarios.push({
      name: `primitive result ${String(value)}, async=${asynchronous}`,
      setup: () => ({
        args: [styleSource, () => (asynchronous ? Promise.resolve(value) : value)],
        events: [],
      }),
    });
  }
}

scenarios.push({
  name: "then getter is inspected on every callback result",
  setup: () => {
    const events: string[] = [];
    return {
      events,
      args: [
        styleSource,
        (content: string) => {
          events.push("callback " + content);
          if (content === "a") return Promise.resolve({ code: "first" });
          return {
            // oxlint-disable-next-line unicorn/no-thenable -- Verify observable PromiseLike getters.
            get then() {
              events.push("then getter");
              throw new Error("getter failed");
            },
          };
        },
      ],
    };
  },
});

scenarios.push({
  name: "callback receives undefined this and two arguments",
  setup: () => {
    const events: string[] = [];
    return {
      events,
      args: [
        styleSource,
        function (this: unknown, content: string) {
          events.push(`${content}:${this === undefined}:${arguments.length}`);
          return null;
        },
      ],
    };
  },
});

for (const { name, setup } of scenarios)
  test("preprocessStyles public behavior matches official: " + name, async () => {
    const expected = await observe(reference, setup);
    assert.deepEqual(await observe(preprocessStyles, setup), expected, "WASM");
    assert.deepEqual(await observe(esmPreprocessStyles, setup), expected, "built ESM");
  });
