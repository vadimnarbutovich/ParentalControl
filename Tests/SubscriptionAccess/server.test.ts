import assert from "node:assert/strict";
import test from "node:test";
import { verifyRevenueCatAccess, VerificationUnavailable, RC_PROJECT, RC_ENTITLEMENT } from "../../supabase/functions/_shared/revenuecat-access.ts";
import { decideFamilyAccess, DEMO_MS, PAID_OFFLINE_LEASE_MS } from "../../supabase/functions/_shared/family-access-policy.ts";

const now = 1_792_576_800_000;
const attached = { object: "list", items: [{ id: RC_ENTITLEMENT, project_id: RC_PROJECT, state: "active" }], next_page: null };
const subscription = { environment: "production", store: "app_store", product_id: "prodff545d5d7b",
  gives_access: true, current_period_starts_at: now - 1000, current_period_ends_at: now + 100000,
  entitlements: attached, auto_renewal_status: "will_not_renew" };
const lifetime = { environment: "production", store: "app_store", product_id: "prod2046b253a9", status: "owned", entitlements: attached };
const page = (items: unknown[], next_page: string | null = null) => Response.json({ object: "list", items, next_page });
function verify(subs: unknown[] = [], purchases: unknown[] = [], environment: "production" | "sandbox" = "production") {
  return verifyRevenueCatAccess({ secret: "sk_test_fixture_only", customerID: "fixture", environment, now,
    fetcher: async (input, init) => {
      const url = new URL(String(input));
      assert.equal(url.searchParams.get("environment"), environment);
      assert.equal(init?.redirect, "error");
      return page(url.pathname.endsWith("/subscriptions") ? subs : purchases);
    } });
}
test("cancelled renewal retains paid access", async () => {
  assert.deepEqual(await verify([subscription]), { status: "active", lifetime: false, expiresAt: now + 100000 });
});
test("empty successful responses confirm no purchase", async () => {
  assert.equal((await verify()).status, "inactive");
});
test("sandbox does not grant production; explicit test environment does", async () => {
  const row = { ...subscription, environment: "sandbox" };
  assert.equal((await verify([row])).status, "inactive");
  assert.equal((await verify([row], [], "sandbox")).status, "active");
});
test("lifetime requires owned state and correct product and entitlement", async () => {
  assert.deepEqual(await verify([], [lifetime]), { status: "active", lifetime: true, expiresAt: null });
  assert.equal((await verify([], [{ ...lifetime, status: "refunded" }])).status, "inactive");
  assert.equal((await verify([], [{ ...lifetime, product_id: "other" }])).status, "inactive");
  assert.equal((await verify([], [{ ...lifetime, entitlements: { ...attached, items: [] } }])).status, "inactive");
});
test("inactive subscription and wrong store never grant", async () => {
  assert.equal((await verify([{ ...subscription, gives_access: false }])).status, "inactive");
  assert.equal((await verify([{ ...subscription, store: "test_store" }])).status, "inactive");
});
test("bad dates produce unknown, not revocation", async () => {
  for (const end of [null, "tomorrow", now - 1001, Infinity]) {
    await assert.rejects(verify([{ ...subscription, current_period_ends_at: end }]), VerificationUnavailable);
  }
});
test("explicit RevenueCat billing grace gets a short verified lease", async () => {
  const result = await verify([{ ...subscription, status: "in_grace_period", current_period_ends_at: now - 1 }]);
  assert.deepEqual(result, { status: "active", lifetime: false, expiresAt: now + 300000 });
});
test("configuration errors do not call the network", async () => {
  await assert.rejects(verifyRevenueCatAccess({ secret: "", customerID: "fixture", environment: "production",
    fetcher: async () => { throw new Error("must not execute"); } }), /configuration/);
});
test("HTTP failures and malformed success are unknown", async () => {
  for (const code of [401, 403, 404, 429, 500]) {
    await assert.rejects(verifyRevenueCatAccess({ secret: "sk_test", customerID: "fixture", environment: "production",
      fetcher: async () => new Response("private upstream body", { status: code }) }), /upstream/);
  }
  await assert.rejects(verifyRevenueCatAccess({ secret: "sk_test", customerID: "fixture", environment: "production",
    fetcher: async () => Response.json({}) }), /invalid_response/);
});
test("pagination reads later purchases without exposing bearer to another host", async () => {
  for (const bad of ["https://attacker.example/collect", "/v2/projects/another/customers/fixture/purchases"]) {
    let calls = 0;
    await assert.rejects(verifyRevenueCatAccess({ secret: "sk_test", customerID: "fixture", environment: "production",
      fetcher: async (input) => {
        assert.equal(new URL(String(input)).origin, "https://api.revenuecat.com"); calls++;
        return page([], bad);
      } }), /invalid_response/);
    assert.equal(calls, 2);
  }
  const result = await verifyRevenueCatAccess({ secret: "sk_test", customerID: "fixture", environment: "production", now,
    fetcher: async (input) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith("/subscriptions")) return page([]);
      return url.searchParams.has("starting_after") ? page([lifetime])
        : page([], `${url.pathname}?starting_after=first`);
    } });
  assert.equal(result.status, "active");
});
test("pagination cycles are bounded", async () => {
  let calls = 0;
  await assert.rejects(verifyRevenueCatAccess({ secret: "sk_test", customerID: "fixture", environment: "production",
    fetcher: async (input) => { calls++; return page([], String(input)); } }), /invalid_response/);
  assert.equal(calls, 2);
});
const record = { enabled: true, parentReady: true, childReady: true, trialStartedAt: now,
  purchase: null, verifiedAt: null };
test("rollout is opt-in and requires both devices", () => {
  assert.equal(decideFamilyAccess({ ...record, enabled: false }, now).state, "legacy");
  for (const change of [{ parentReady: false }, { childReady: false }]) {
    assert.equal(decideFamilyAccess({ ...record, ...change }, now).controlAllowed, false);
  }
});
test("demo ends at exactly 24 hours and cannot move with repeated checks", () => {
  assert.equal(decideFamilyAccess(record, now).controlUntil, now + DEMO_MS);
  assert.equal(decideFamilyAccess(record, now + DEMO_MS - 1).controlAllowed, true);
  assert.equal(decideFamilyAccess(record, now + DEMO_MS).controlAllowed, false);
  assert.equal(decideFamilyAccess({ ...record, trialStartedAt: null }, now).state, "setup");
});
test("lifetime uses last confirmed state while verification is unavailable", () => {
  const paid = { ...record, trialStartedAt: now - DEMO_MS * 2, verifiedAt: now,
    purchase: { status: "active" as const, lifetime: true, expiresAt: null } };
  assert.equal(decideFamilyAccess(paid, now).controlUntil, now + PAID_OFFLINE_LEASE_MS);
  assert.equal(decideFamilyAccess(paid, now + PAID_OFFLINE_LEASE_MS).controlAllowed, true);
});
test("paid cache survives billing boundary and extended offline use", () => {
  const paid = { ...record, trialStartedAt: now - DEMO_MS * 2, verifiedAt: now,
    purchase: { status: "active" as const, lifetime: false, expiresAt: now + 1000 } };
  assert.equal(decideFamilyAccess(paid, now).controlUntil, now + PAID_OFFLINE_LEASE_MS);
  assert.equal(decideFamilyAccess(paid, now + 1000).controlAllowed, true);
  assert.equal(decideFamilyAccess(paid, now + PAID_OFFLINE_LEASE_MS * 4).controlAllowed, true);
  assert.equal(decideFamilyAccess({ ...paid, verifiedAt: now + 1 }, now).controlAllowed, false);
});
test("negative verification overrides old grace, never reopens without purchase", () => {
  const paid = { ...record, trialStartedAt: now - DEMO_MS * 2, verifiedAt: now,
    paidAccessUntil: now + PAID_OFFLINE_LEASE_MS };
  for (const purchase of [null, { status: "inactive" as const, lifetime: false as const, expiresAt: null }]) {
    assert.equal(decideFamilyAccess({ ...paid, purchase }, now + 1000).controlAllowed, false);
    assert.equal(decideFamilyAccess({ ...paid, purchase, verifiedAt: now + 1000 }, now + PAID_OFFLINE_LEASE_MS).controlAllowed, false);
  }
});
test("already renewed subscription uses ends_at before the old period boundary", async () => {
  assert.deepEqual(await verify([{ ...subscription, auto_renewal_status: "has_already_renewed",
    current_period_ends_at: now + 7000, ends_at: now + 187000 }]),
    { status: "active", lifetime: false, expiresAt: now + 187000 });
});
test("stale active flag with an expired period cannot synthesize a fresh purchase", async () => {
  await assert.rejects(verify([{ ...subscription, status: "active", current_period_ends_at: now - 1 }]), VerificationUnavailable);
});
