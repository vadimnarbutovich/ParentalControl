import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { accessAllows, purchaseConfirmed } from "../../supabase/functions/_shared/access-service.ts";

test("setup permits configuration, never control or balance adjustments", () => {
  const setup = { enforced: true, state: "setup", controlUntilMs: null };
  for (const action of ["parent_poll", "child_poll", "generate_pairing_code", "join_pairing_code", "unlink_devices", "set_parent_pin"])
    assert.equal(accessAllows(setup, action), true, action);
  assert.equal(accessAllows(setup, "change_daily_budget", { kind: "limit" }), true);
  for (const action of ["change_daily_budget", "replace_focus_command", "queue_focus_command",
    "set_local_manual_block", "request_child_location", "upsert_block_schedule", "upsert_child_task", "approve_child_task",
    "adjust_child_balance", "fetch_pending_commands", "begin_location_push"])
    assert.equal(accessAllows(setup, action, { kind: "adjustment" }), false, action);
});

test("expired access cannot reuse the setup configuration exception", () => {
  for (const state of ["expired", "verification_required"]) {
    const snapshot = { enforced: true, state };
    assert.equal(accessAllows(snapshot, "change_daily_budget", { kind: "limit" }), false);
    assert.equal(accessAllows(snapshot, "parent_poll"), false);
    assert.equal(accessAllows(snapshot, "unlink_devices"), true);
  }
});

test("only a current canonical purchase confirms success, not demo or unknown", () => {
  const now = Date.now();
  const owner = { purchase_state: "active", verified_at: new Date(now - 1000).toISOString(),
    purchase_until: new Date(now + 60000).toISOString(), lifetime: false };
  assert.equal(purchaseConfirmed(owner, now), true);
  for (const delta of [{ purchase_state: "unknown" }, { purchase_state: "inactive" },
    { verified_at: null }, { verified_at: new Date(now + 1000).toISOString() },
    { verified_at: new Date(now - 86400000).toISOString() }, { purchase_until: null },
    { purchase_until: new Date(now).toISOString() }])
    assert.equal(purchaseConfirmed({ ...owner, ...delta }, now), false, JSON.stringify(delta));
  assert.equal(purchaseConfirmed({ ...owner, lifetime: true, purchase_until: null }, now), true);
  assert.equal(purchaseConfirmed(null, now), false);
});

test("enabling removal protection is gated, disabling remains PIN-only recovery", () => {
  const source = readFileSync(new URL("../../ParentalControl/App/AppState.swift", import.meta.url), "utf8");
  const enable = source.split("func enableRemovalProtectionFromParentMode()")[1].split("func allowRemovalFromParentMode()")[0];
  assert.ok(enable.indexOf("guard FamilyAccessStore.allowed") < enable.indexOf("try await screenTimeService.enableRemovalProtection()"));
  const disable = source.split("func allowRemovalFromParentMode()")[1].split("func completeOnboarding()")[0];
  assert.ok(disable.includes("isParentModeActive"));
  assert.ok(!disable.includes("requireFamilyAccess"));
  assert.ok(!disable.includes("FamilyAccessStore.allowed"));
});

test("purchase and restore cannot succeed using optional verifier or SDK flag alone", () => {
  const source = readFileSync(new URL("../../ParentalControl/Services/SubscriptionService.swift", import.meta.url), "utf8");
  assert.match(source, /verifyServerPurchase: \(\(\) async throws -> Bool\)\?/);
  assert.match(source, /let verifier = automatic \? recheckServerPurchase : verifyServerPurchase/);
  assert.match(source, /if try await verifier\?\(\) == true/);
  assert.match(source, /guard await confirmServerPurchase\(\) else \{ return \.pendingVerification \}/);
  assert.ok(source.includes('L10n.tr("paywall.purchase.pending_verification")'));
});
