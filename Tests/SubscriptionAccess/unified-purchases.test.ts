import assert from "node:assert/strict";
import test from "node:test";
import { refreshOwner } from "../../supabase/functions/_shared/access-service.ts";
import { RC_ENTITLEMENT, RC_PROJECT } from "../../supabase/functions/_shared/revenuecat-access.ts";

test("server purchase verification ignores legacy owner Sandbox flag and keeps existing RPC/request count", async () => {
  const originalFetch = globalThis.fetch;
  try {
    for (const sandbox of [false, true, undefined]) {
      const calls: string[] = [];
      let saved: any;
      const end = Date.now() + 600000;
      const db = { rpc: async (name: string, args: any) => {
        calls.push(name);
        if (name === "pc_access_claim_refresh") return { data: { token: "fixture-token", customerID: "server-owned", sandbox } };
        assert.equal(name, "pc_access_finish_refresh"); saved = args;
        return { data: true };
      } };
      let requests = 0;
      globalThis.fetch = async (input) => {
        requests++;
        const url = new URL(String(input));
        assert.ok(url.pathname.includes("/customers/server-owned/"));
        assert.equal(url.searchParams.has("environment"), false);
        return Response.json({ object: "list", next_page: null, items: url.pathname.endsWith("/subscriptions") ? [{
          environment: "sandbox", store: "app_store", product_id: "prodef86c9af44",
          gives_access: true, current_period_starts_at: end - 1200000, current_period_ends_at: end,
          entitlements: { object: "list", next_page: null, items: [{ id: RC_ENTITLEMENT, project_id: RC_PROJECT, state: "active" }] },
        }] : [] });
      };
      assert.equal(await refreshOwner(db, "owner", "sk_fixture"), true);
      assert.equal(saved.p_state, "active");
      assert.equal(saved.p_until, new Date(end).toISOString());
      assert.equal(saved.p_token, "fixture-token");
      assert.equal(requests, 2);
      assert.deepEqual(calls, ["pc_access_claim_refresh", "pc_access_finish_refresh"]);
    }
  } finally { globalThis.fetch = originalFetch; }
});

test("cooldown still avoids all RevenueCat requests", async () => {
  let calls = 0;
  const db = { rpc: async (name: string) => { calls++; assert.equal(name, "pc_access_claim_refresh"); return { data: null }; } };
  assert.equal(await refreshOwner(db, "owner", "sk_fixture"), false);
  assert.equal(calls, 1);
});
