import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { permitsAccessReleaseAck } from "../../supabase/functions/_shared/access-release-ack.ts";

const payload = { status: "applied", accessReleaseRevision: 4 };
const access = { enforced: true, state: "expired", revision: 4 };

// Execute the real handler with an in-memory DB double. Only its two TypeScript
// annotations are removed; validation and update conditions come from production.
const serverSource = readFileSync(new URL("../../supabase/functions/parental-control-sync/index.ts", import.meta.url), "utf8");
const handlerSource = serverSource.slice(serverSource.indexOf("async function ackCommand("),
  serverSource.indexOf("async function upsertChildDayStats("))
  .replace("deviceId: string, payload: Json, access: Json): Promise<Response>", "deviceId, payload, access)")
  .replace("const patch: Record<string, unknown>", "const patch");
const handler = new Function("supabase", "asString", "errorResponse", "okResponse", "permitsAccessReleaseAck",
  `${handlerSource}; return ackCommand;`);
async function runAck(options: { target?: string; type?: string; state?: string; status?: string; dbError?: boolean; legacy?: boolean } = {}) {
  const row = { id: "command", target_device_id: options.target ?? "child",
    command_type: options.type ?? "tasks_updated", status: options.status ?? "sent" };
  let reads = 0, writes = 0;
  const db = { from: () => ({
    select: () => ({ eq: () => ({ single: async () => { reads++; return { data: row, error: null }; } }) }),
    update: (patch: object) => ({ eq: () => ({ in: async (_field: string, statuses: string[]) => {
      if (options.dbError) return { error: { message: "offline" } };
      if (statuses.includes(row.status)) { writes++; Object.assign(row, patch); }
      return { error: null };
    } }) }),
  }) };
  const ack = handler(db, (value: unknown) => typeof value === "string" ? value : null,
    (_error: string, status: number) => ({ status }), () => ({ status: 200 }), permitsAccessReleaseAck);
  const result = await ack("child", { commandID: row.id, ...(options.legacy ? { status: "applied" } : payload) },
    { ...access, state: options.state ?? "expired" });
  return { code: result.status, reads, writes, status: row.status };
}
test("real ACK handler completes release, preserves retry on errors and remains backwards compatible", async () => {
  assert.deepEqual(await runAck(), { code: 200, reads: 1, writes: 1, status: "applied" });
  assert.deepEqual(await runAck({ target: "other" }), { code: 403, reads: 1, writes: 0, status: "sent" });
  assert.deepEqual(await runAck({ type: "start_focus" }), { code: 409, reads: 1, writes: 0, status: "sent" });
  assert.deepEqual(await runAck({ state: "paid" }), { code: 409, reads: 1, writes: 0, status: "sent" });
  assert.deepEqual(await runAck({ dbError: true }), { code: 400, reads: 1, writes: 0, status: "sent" });
  for (const status of ["failed", "expired", "cancelled"]) {
    assert.deepEqual(await runAck({ status }), { code: 200, reads: 1, writes: 0, status });
  }
  assert.deepEqual(await runAck({ legacy: true, type: "start_focus", state: "paid" }),
    { code: 200, reads: 1, writes: 1, status: "applied" });
});

test("only the matching expired tasks wake can acknowledge release", () => {
  assert.equal(permitsAccessReleaseAck(payload, "tasks_updated", access), true);
  for (const type of ["start_focus", "end_focus", "request_location", "schedule_start", "schedule_end", ""]) {
    assert.equal(permitsAccessReleaseAck(payload, type, access), false);
  }
  for (const revision of [undefined, null, "4", 0, -1, 4.5, 5, NaN, Infinity]) {
    assert.equal(permitsAccessReleaseAck({ ...payload, accessReleaseRevision: revision }, "tasks_updated", access), false);
  }
  for (const state of ["paid", "demo", "setup", "verification_required", undefined]) {
    assert.equal(permitsAccessReleaseAck(payload, "tasks_updated", { ...access, state }), false);
  }
  assert.equal(permitsAccessReleaseAck(payload, "tasks_updated", { ...access, enforced: false }), false);
  assert.equal(permitsAccessReleaseAck({ ...payload, status: "failed" }, "tasks_updated", access), false);
});

test("server validates stored target and type before updating; no extra access query or terminal resurrection", () => {
  const source = readFileSync(new URL("../../supabase/functions/parental-control-sync/index.ts", import.meta.url), "utf8");
  const ack = source.split("async function ackCommand(")[1].split("async function upsertChildDayStats")[0];
  assert.match(source, /ackCommand\(authed.deviceId, payload, access\)/);
  assert.ok(ack.indexOf("command.target_device_id !== deviceId") < ack.indexOf("permitsAccessReleaseAck("));
  assert.ok(ack.indexOf("permitsAccessReleaseAck(") < ack.indexOf(".update(patch)"));
  assert.match(ack, /"accessReleaseRevision" in payload/); // Old clients unchanged.
  assert.match(ack, /permitsAccessReleaseAck\(payload, command.command_type, access\)/);
  assert.match(ack, /\.in\("status", \["queued", "sent", "delivered", "applied"\]\)/);
  assert.ok(!ack.includes("accessSnapshot("));
});

test("NSE ACK follows successful bounded release and context checks, not a generic denial", () => {
  const source = readFileSync(new URL("../../NotificationServiceExtension/RemoteControlProcessor.swift", import.meta.url), "utf8");
  assert.match(source, /catch Failure.accessReleased\(let revision\)/);
  assert.match(source, /guard type == "tasks_updated" else \{ throw Failure.http\(402\) \}/);
  assert.match(source, /FamilyAccessStore.receipt\?\.lease.revision == revision else \{ throw Failure.stale \}/);
  assert.match(source, /let released = try await ControlSystemWorker.shared.run/);
  assert.match(source, /return FamilyAccessEnforcement.releaseIfNeeded\(\)\s*\}\s*try checkContext\(\)/);
  assert.match(source, /action == "child_poll", released, !FamilyAccessStore.allowed/);
  assert.match(source, /current: FamilyAccessStore.receipt\?\.lease, family: family/);
  assert.match(source, /guard action == "ack_command", \(200..<300\).contains\(http.statusCode\)/);
  assert.match(source, /recordDiagnostic\("access_release_acknowledged"\)/);
});
