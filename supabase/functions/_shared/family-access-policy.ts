import type { PurchaseAccess } from "./revenuecat-access.ts";

export const DEMO_MS = 24 * 60 * 60 * 1000;
export const PAID_OFFLINE_LEASE_MS = 24 * 60 * 60 * 1000;
export const RECOVERY_POLL_MS = 15 * 60 * 1000;

export type AccessRecord = {
  enabled: boolean;
  parentReady: boolean;
  childReady: boolean;
  trialStartedAt: number | null;
  purchase: PurchaseAccess | null;
  verifiedAt: number | null;
  // Legacy wire-continuity field. Never overrides a confirmed inactive state.
  paidAccessUntil?: number | null;
};

export type AccessDecision = {
  state: "legacy" | "setup" | "demo" | "paid" | "verification_required" | "expired";
  // The device must not enforce a parental shield beyond this lease. This is
  // independent of whether navigation/settings/purchase UI is available.
  controlAllowed: boolean;
  controlUntil: number | null;
  syncAllowed: boolean;
  nextCheckAt: number;
};

// Pure server-clock policy. Existing families remain legacy until an explicit,
// server-owned rollout enrols BOTH capable devices. Never start a trial here:
// starting it requires an atomic database transaction after setup confirmation.
export function decideFamilyAccess(record: AccessRecord, now: number): AccessDecision {
  if (!Number.isSafeInteger(now) || now <= 0) throw new Error("Invalid server time");
  const result = (state: AccessDecision["state"], allowed: boolean, until: number | null): AccessDecision => ({
    state, controlAllowed: allowed, controlUntil: until, syncAllowed: allowed,
    nextCheckAt: until === null ? now + RECOVERY_POLL_MS : Math.min(now + RECOVERY_POLL_MS, until),
  });
  if (!record.enabled) return result("legacy", true, null);
  if (!record.parentReady || !record.childReady) return result("setup", false, null);
  const verified = record.verifiedAt;
  if (verified !== null && (!Number.isSafeInteger(verified) || verified <= 0 || verified > now)) {
    return result("verification_required", false, null);
  }
  // purchase is the LAST CONFIRMED decision. Verification errors do not change
  // it; a successful inactive response does. Wire dates remain bounded for v1
  // compatibility, but paid clients don't infer expiration from a local clock.
  if (record.purchase?.status === "active" && verified !== null) {
    return result("paid", true, now + PAID_OFFLINE_LEASE_MS);
  }
  if (record.trialStartedAt !== null && Number.isSafeInteger(record.trialStartedAt) &&
      record.trialStartedAt > 0 && record.trialStartedAt <= now) {
    const demoEnd = record.trialStartedAt + DEMO_MS;
    if (demoEnd > now) return result("demo", true, demoEnd);
  }
  if (record.trialStartedAt === null) return result("setup", false, null);
  if (record.purchase === null || record.verifiedAt === null ||
      record.verifiedAt + PAID_OFFLINE_LEASE_MS <= now) {
    return result("verification_required", false, null);
  }
  return result("expired", false, null);
}

// Kept explicit for the eventual middleware: "end_focus" is not a universal
// safe release because other daily-budget/schedule shields may still be active.
export const RECOVERY_ACTIONS = new Set([
  "access_status", "verify_purchase", "purchase_identity", "release_control",
  "unlink_devices", "delete_account", "ack_access_release",
]);
