import pending from "./fixtures/yuku-pending.json" with { type: "json" };

// Exact inputs only; recovery-policy differences remain active.
export function isYukuPending(source: string, check: "ast" | "syntax" | "tsx"): boolean {
  return pending.cases.some((item) => item.source === source && item.checks.includes(check));
}
