// Run: node --experimental-strip-types --test Tests/LocationPush/apns-routing.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { sendApnsToDevice } from "../../supabase/functions/_shared/apns-routing.ts";

function database(environment: string | null, channel: "alert" | "location") {
  const calls: unknown[] = [];
  const row = { id: "test-device", apns_environment: channel === "alert" ? environment : "production",
    location_push_environment: channel === "location" ? environment : null };
  const db = { from: () => ({
    select: () => ({ eq: (column: string) => {
      assert.equal(column, channel === "location" ? "location_push_token" : "apns_token");
      return Promise.resolve({ data: [row], error: null });
    } }),
    update: (patch: unknown) => { calls.push(patch); return {
      in: () => ({ eq: () => ({ is: () => Promise.resolve({ error: null }) }) })
    }; },
  }) };
  return { db, calls };
}

for (const channel of ["alert", "location"] as const) {
  test(`${channel}: known production token stays on production and preserves payload`, async () => {
    const { db, calls } = database("production", channel);
    const original = globalThis.fetch;
    let attempts = 0;
    globalThis.fetch = async (url, request) => {
      attempts++;
      assert.equal(url, "https://api.push.apple.com/3/device/token");
      assert.equal(request?.body, "unchanged");
      return new Response("", { status: 200 });
    };
    try {
      await sendApnsToDevice(db as never, "token", "api.sandbox.push.apple.com", { body: "unchanged" }, channel);
      assert.equal(attempts, 1); assert.deepEqual(calls, []);
    } finally { globalThis.fetch = original; }
  });
}

test("location: discover environment independently from the normal alert token", async () => {
  const { db, calls } = database(null, "location");
  const original = globalThis.fetch;
  const urls: string[] = [];
  globalThis.fetch = async url => {
    urls.push(String(url));
    return urls.length === 1
      ? new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 })
      : new Response("", { status: 200 });
  };
  try {
    await sendApnsToDevice(db as never, "token", "api.sandbox.push.apple.com", {}, "location");
    assert.equal(urls.length, 2);
    assert.ok(urls[1].includes("api.push.apple.com"));
    assert.deepEqual(calls, [{ location_push_environment: "production" }]);
  } finally { globalThis.fetch = original; }
});

test("location: uncertain network failure never resends a push", async () => {
  const { db } = database(null, "location");
  const original = globalThis.fetch;
  let attempts = 0;
  globalThis.fetch = async () => { attempts++; throw new Error("offline"); };
  try {
    await assert.rejects(sendApnsToDevice(db as never, "token", "api.sandbox.push.apple.com", {}, "location"));
    assert.equal(attempts, 1);
  } finally { globalThis.fetch = original; }
});
