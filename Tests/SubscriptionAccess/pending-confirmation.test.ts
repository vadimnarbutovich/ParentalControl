import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";

const read = (name: string) => readFileSync(new URL(`../../ParentalControl/${name}`, import.meta.url), "utf8");
const state = read("App/AppState.swift");
const service = read("Services/SubscriptionService.swift");
const view = read("Views/PaywallView.swift");

test("scheduled recovery replaces normal access request and cannot extend its own window", () => {
  const refresh = state.split("func refreshFamilyAccess(force:")[1].split("func adoptFamilyAccess()")[0];
  assert.ok(refresh.indexOf("guard force ||") < refresh.indexOf("retryPendingPurchaseConfirmation"));
  assert.match(refresh, /PendingPurchaseRecovery.shouldRetry/);
  assert.match(refresh, /retryPendingPurchaseConfirmation\(automatic: true\)\s+return/);
  assert.ok(refresh.indexOf("retryPendingPurchaseConfirmation") < refresh.indexOf("remoteSyncService.accessStatus"));
  const callback = state.split("service.recheckServerPurchase =")[1].split("service.onEntitlementChange")[0];
  assert.match(callback, /verifyServerPurchase\(restartRecovery: false\)/);
  const verify = state.split("private func verifyServerPurchase(restartRecovery:")[1].split("/// Parent → backend")[0];
  assert.match(verify, /if restartRecovery \{\s+purchaseRecoveryUntil = Date\(\).addingTimeInterval\(120\)/);
  assert.match(verify, /if confirmed \{ purchaseRecoveryUntil = nil \}/);
});

test("retry is serialized, verifier-only and independent of product loading", () => {
  const retry = service.split("func retryPendingPurchaseConfirmation(")[1].split("private func confirmServerPurchase")[0];
  assert.match(retry, /guard isAwaitingServerConfirmation, !isLoading/);
  assert.match(retry, /isLoading = true/);
  assert.match(retry, /defer \{ isLoading = false \}/);
  assert.match(retry, /confirmServerPurchase\(automatic: automatic\)/);
  assert.ok(!/Purchases.shared|preparePurchaseIdentity|loadOfferings|Task.sleep/.test(retry));
  const confirm = service.split("private func confirmServerPurchase(")[1].split("/// Child-сторона")[0];
  assert.match(confirm, /if try await verifier\?\(\) == true \{\s+purchaseConfirmationState.recordVerification\(true\)/);
  assert.ok(!/FamilyAccessStore.allowed|hasActiveEntitlement/.test(confirm));
  assert.match(confirm, /lastErrorMessage = nil/);
  assert.match(confirm, /recordVerification\(false\)/);
});

test("paywall observes late completion, both retry controls use verification instead of payment", () => {
  assert.match(view, /onChange\(of: subscriptionService.purchaseConfirmationState\)/);
  assert.match(view, /PurchaseConfirmationState.shouldDismiss\(previous: previous, current: current\) \{\s+isPresented = false/);
  assert.equal((view.match(/await subscriptionService.retryPendingPurchaseConfirmation\(\)/g) ?? []).length, 2);
  assert.match(view, /disabled\(busy \|\| \(!subscriptionService.isAwaitingServerConfirmation/);
  const adopt = service.split("func refreshAccessState()")[1].split("private func preparePurchaseIdentity()")[0];
  assert.ok(!adopt.includes("recordVerification(true)"), "Cached access is not a new purchase confirmation");
});
