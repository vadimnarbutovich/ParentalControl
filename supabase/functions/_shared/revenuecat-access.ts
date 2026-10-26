// Server-only API v2 verifier. Never accepts an isPro flag or a customer ID from
// an unauthenticated caller. The caller must resolve a server-owned identity.
// https://www.revenuecat.com/docs/api-v2/customer/resources
export const RC_PROJECT = "proj77ee7cb3";
export const RC_ENTITLEMENT = "entl9fb6907f37";
const SUBSCRIPTIONS = new Set(["prodff545d5d7b", "prodef86c9af44"]);
const LIFETIME = "prod2046b253a9";
const ORIGIN = "https://api.revenuecat.com";

export type PurchaseAccess =
  // expiresAt is the verified access horizon, not necessarily the paid billing
  // period end: during billing grace RevenueCat can explicitly give access
  // beyond that period. Such a grant is rechecked after five minutes.
  | { status: "active"; lifetime: boolean; expiresAt: number | null }
  | { status: "inactive"; lifetime: false; expiresAt: null };

// All failures are unknown, NOT proof that a paid subscription expired.
// Only fixed reasons are exposed: never raw HTTP bodies/headers/customer data.
export class VerificationUnavailable extends Error {
  readonly reason: "configuration" | "network" | "upstream" | "invalid_response";
  constructor(reason: VerificationUnavailable["reason"]) {
    super(`Purchase verification unavailable: ${reason}`);
    this.reason = reason;
  }
}

type ObjectValue = Record<string, unknown>;
function object(value: unknown): ObjectValue {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new VerificationUnavailable("invalid_response");
  }
  return value as ObjectValue;
}
function timestamp(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) {
    throw new VerificationUnavailable("invalid_response");
  }
  return value;
}
function entitlementAttached(value: unknown): boolean {
  const list = object(value);
  if (list.object !== "list" || !Array.isArray(list.items)) {
    throw new VerificationUnavailable("invalid_response");
  }
  const found = list.items.some((raw) => {
    const entry = object(raw);
    return entry.id === RC_ENTITLEMENT && entry.project_id === RC_PROJECT && entry.state === "active";
  });
  // Never silently turn a truncated entitlement list into a negative decision.
  if (!found && list.next_page != null) throw new VerificationUnavailable("invalid_response");
  return found;
}

export async function verifyRevenueCatAccess(options: {
  secret: string;
  customerID: string;
  now?: number;
  fetcher?: typeof fetch;
}): Promise<PurchaseAccess> {
  const { secret, customerID } = options;
  if (!/^sk_[A-Za-z0-9_-]+$/.test(secret) || !customerID || customerID.length > 1500) {
    throw new VerificationUnavailable("configuration");
  }
  const now = options.now ?? Date.now();
  timestamp(now);
  const fetcher = options.fetcher ?? fetch;
  const base = `/v2/projects/${RC_PROJECT}/customers/${encodeURIComponent(customerID)}`;
  // One deadline across pagination AND both collections; no unbounded retries.
  const signal = AbortSignal.timeout(8_000);
  async function collection(resource: "subscriptions" | "purchases"): Promise<ObjectValue[]> {
    const path = `${base}/${resource}`;
    // RevenueCat returns both Apple environments when the filter is omitted.
    // App Review needs Sandbox too. No client environment flag or owner allowlist.
    let next: string | null = `${path}?limit=100`;
    const visited = new Set<string>();
    const rows: ObjectValue[] = [];
    while (next !== null) {
      let url: URL;
      try { url = new URL(next, ORIGIN); }
      catch { throw new VerificationUnavailable("invalid_response"); }
      // A compromised/malformed pagination link must not leak the bearer key.
      if (url.origin !== ORIGIN || url.pathname !== path || url.username || url.password || url.hash ||
          visited.has(url.href) || visited.size >= 10) {
        throw new VerificationUnavailable("invalid_response");
      }
      // Keep subsequent pages unfiltered as well; never silently lose one side.
      url.searchParams.delete("environment");
      url.searchParams.set("limit", "100");
      if (visited.has(url.href)) throw new VerificationUnavailable("invalid_response");
      visited.add(url.href);
      let response: Response;
      try {
        response = await fetcher(url, {
          headers: { Authorization: `Bearer ${secret}`, Accept: "application/json" },
          signal, redirect: "error",
        });
      } catch { throw new VerificationUnavailable("network"); }
      // Even 404 can be a configuration/identity propagation error. Do not revoke
      // cached paid access on it. A confirmed empty 200 list is the negative case.
      if (!response.ok) throw new VerificationUnavailable("upstream");
      let data: ObjectValue;
      try { data = object(await response.json()); }
      catch { throw new VerificationUnavailable("invalid_response"); }
      if (data.object !== "list" || !Array.isArray(data.items) || data.items.length > 100 ||
          !(data.next_page === null || typeof data.next_page === "string")) {
        throw new VerificationUnavailable("invalid_response");
      }
      rows.push(...data.items.map(object));
      next = data.next_page as string | null;
    }
    return rows;
  }
  const [subscriptions, purchases] = await Promise.all([collection("subscriptions"), collection("purchases")]);
  let expiresAt = 0;
  let uncertain = false;
  for (const row of subscriptions) {
    if (!["production", "sandbox"].includes(String(row.environment)) || row.store !== "app_store" || !SUBSCRIPTIONS.has(String(row.product_id))) continue;
    try {
      if (typeof row.gives_access !== "boolean") throw new VerificationUnavailable("invalid_response");
      if (!row.gives_access || !entitlementAttached(row.entitlements)) continue;
      // RevenueCat's gives_access includes cancellation-with-time-remaining and
      // store billing grace. Never use auto_renewal_status as the access decision.
      const currentEnd = timestamp(row.current_period_ends_at);
      // Apple can renew before the current period ends. RevenueCat explicitly
      // exposes the already-paid next period in ends_at (not pending_changes).
      const end = row.auto_renewal_status === "has_already_renewed"
        ? Math.max(currentEnd, timestamp(row.ends_at)) : currentEnd;
      const start = timestamp(row.current_period_starts_at);
      if (start > now || end <= start) throw new VerificationUnavailable("invalid_response");
      if (end <= now && row.status !== "in_grace_period") {
        // Conflicting/stale API data is unknown, NOT a fresh five-minute purchase
        // and NOT evidence of expiry. In particular it must not revive an owner
        // whose expiration was already confirmed by a newer canonical response.
        throw new VerificationUnavailable("invalid_response");
      }
      expiresAt = Math.max(expiresAt, end > now ? end : now + 5 * 60 * 1000);
    } catch (error) {
      if (!(error instanceof VerificationUnavailable)) throw error;
      // One stale/malformed purchase must not mask another verified active one.
      // Without any positive evidence the whole decision stays unknown.
      uncertain = true;
    }
  }
  for (const row of purchases) {
    if (!["production", "sandbox"].includes(String(row.environment)) || row.store !== "app_store" || row.product_id !== LIFETIME) continue;
    try {
      if (typeof row.status !== "string") throw new VerificationUnavailable("invalid_response");
      if (row.status === "owned" && entitlementAttached(row.entitlements)) {
        return { status: "active", lifetime: true, expiresAt: null };
      }
    } catch (error) {
      if (!(error instanceof VerificationUnavailable)) throw error;
      uncertain = true;
    }
  }
  if (expiresAt <= now && uncertain) throw new VerificationUnavailable("invalid_response");
  return expiresAt > now
    ? { status: "active", lifetime: false, expiresAt }
    : { status: "inactive", lifetime: false, expiresAt: null };
}
