import assert from "node:assert/strict";
import test from "node:test";
import { authenticateWebhook, webhookEvent, renewalNeedsRetry } from "../../supabase/functions/_shared/access-webhook.ts";
import { accessAllows } from "../../supabase/functions/_shared/access-service.ts";
const secret = "fixture-only-authorization-value-not-a-real-secret";
const a = "pc-11111111-1111-1111-1111-111111111111";
const b = "pc-22222222-2222-2222-2222-222222222222";
test("early renewal retries canonical verification without trusting event as a grant", () => {
  const now = 1792658857000;
  const event = webhookEvent({ event: { id: "early", app_id: "app09b71b22ed", type: "RENEWAL",
    environment: "SANDBOX", expiration_at_ms: now + 187000, app_user_id: a } });
  const owner = { sandbox_allowed: true, lifetime: false, purchase_until: new Date(now + 7000).toISOString() };
  assert.equal(renewalNeedsRetry(event, owner, now), true);
  assert.equal(renewalNeedsRetry(event, { ...owner, purchase_until: new Date(now + 187000).toISOString() }, now), false);
  assert.equal(renewalNeedsRetry(event, { ...owner, sandbox_allowed: false }, now), false);
  assert.equal(renewalNeedsRetry(event, owner, now + 187000), false);
  assert.equal(renewalNeedsRetry({ id: "refund", test: false, customers: [a] }, owner, now), false);
});
test("webhook requires an exact configured secret", async () => {
  assert.equal(await authenticateWebhook(secret, secret), true);
  for (const candidate of [null, "", "Bearer " + secret, secret + " ", "wrong"]) {
    assert.equal(await authenticateWebhook(candidate, secret), false);
  }
  assert.equal(await authenticateWebhook(secret, ""), false);
});
test("test deliveries cannot change access", () => {
  assert.deepEqual(webhookEvent({ event: { id: "test", type: "TEST", app_user_id: a } }),
    { id: "test", customers: [], test: true });
});
test("transfers recheck both owners, aliases are deduplicated", () => {
  assert.deepEqual(webhookEvent({ event: { id: "transfer", app_id: "app09b71b22ed", type: "TRANSFER",
    transferred_from: [a], transferred_to: [b], aliases: [a, "legacy"] } }).customers, [a, b]);
});
test("other applications and malformed events are rejected", () => {
  for (const event of [null, {}, { id: "x", app_id: "screenblocker" }, { id: "x".repeat(129) }]) {
    assert.throws(() => webhookEvent({ event }));
  }
});
test("paid operations stop at expiry but recovery remains available", () => {
  const expired = { enforced: true, state: "expired", controlUntilMs: null };
  for (const action of ["child_poll", "change_daily_budget", "request_child_location", "report_child_usage", "queue_balance_command"]) {
    assert.equal(accessAllows(expired, action), false);
  }
  for (const action of ["unlink_devices", "fetch_parent_pin", "ack_command", "finish_location_push"]) {
    assert.equal(accessAllows(expired, action), true);
  }
  assert.equal(accessAllows({ enforced: false }, "child_poll"), true);
  assert.equal(accessAllows({ enforced: true, state: "paid", controlUntilMs: Date.now() - 1 }, "child_poll"), false);
  assert.equal(accessAllows({ enforced: true, state: "paid", controlUntilMs: Date.now() + 60000 }, "child_poll"), true);
});
