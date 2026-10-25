import { verifyRevenueCatAccess } from "./revenuecat-access.ts";

// Structural interface keeps this module testable without importing a Deno SDK.
type DB = any;
type Device = { id: string; role: string; family_id: string | null };
export type AccessSnapshot = { enforced: boolean; state?: string; controlUntilMs?: number | null; [key: string]: unknown };
const recovery = new Set(["generate_pairing_code", "join_pairing_code", "register_location_push", "update_apns_token", "unlink_devices", "fetch_parent_pin", "clear_parent_pin", "set_parent_pin", "fetch_link_health", "ack_command", "finish_location_push"]);

export async function accessSnapshot(db: DB, deviceID: string): Promise<AccessSnapshot> {
  const { data, error } = await db.rpc("pc_access_snapshot", { p_device: deviceID });
  if (error || !data || typeof data.enforced !== "boolean") throw new Error("Access status unavailable");
  return data;
}
export function accessAllows(snapshot: AccessSnapshot, action: string, payload: Record<string, unknown> = {}): boolean {
  return !snapshot.enforced || recovery.has(action) ||
    (snapshot.state === "setup" && (["parent_poll", "child_poll"].includes(action) ||
      (action === "change_daily_budget" && payload.kind === "limit"))) ||
    (["paid", "demo"].includes(snapshot.state ?? "") && typeof snapshot.controlUntilMs === "number" && snapshot.controlUntilMs > Date.now());
}

export function purchaseConfirmed(owner: any, now = Date.now()): boolean {
  const verified = Date.parse(owner?.verified_at ?? "");
  return owner?.purchase_state === "active" && Number.isFinite(verified) && verified <= now &&
    verified + 86_400_000 > now && (owner.lifetime === true || Date.parse(owner.purchase_until ?? "") > now);
}
export async function refreshOwner(db: DB, owner: string, secret: string): Promise<boolean> {
  const { data: claim, error } = await db.rpc("pc_access_claim_refresh", { p_owner: owner });
  if (error) throw new Error("Purchase refresh unavailable");
  if (!claim) return false;
  let state = "unknown", until: string | null = null, lifetime = false;
  try {
    const result = await verifyRevenueCatAccess({ secret, customerID: claim.customerID });
    state = result.status; lifetime = result.lifetime;
    until = result.expiresAt === null ? null : new Date(result.expiresAt).toISOString();
  } catch { /* Unknown must not overwrite paid cache or extend its verification time. */ }
  const { data: saved, error: saveError } = await db.rpc("pc_access_finish_refresh", {
    p_owner: owner, p_token: claim.token, p_state: state, p_until: until, p_lifetime: lifetime,
  });
  if (saveError) throw new Error("Purchase refresh unavailable");
  return saved === true && state !== "unknown";
}
export async function accessAction(db: DB, device: Device, action: string, payload: Record<string, unknown>, secret: string): Promise<Record<string, unknown>> {
  if (!["access_status", "purchase_identity", "verify_purchase", "release_control", "resume_control"].includes(action)) throw new Error("Unknown access action");
  if (action !== "access_status" && device.role !== "parent") throw new Error("Parent required");
  if (action === "access_status" || action === "purchase_identity") {
    const { error } = await db.rpc("pc_access_prepare", { p_device: device.id, p_ready: payload.ready === true && payload.protocolVersion === 1 });
    if (error) throw new Error("Access setup unavailable");
  }
  if (action === "purchase_identity") {
    const { data, error } = await db.from("pc_access_owners").select("customer_id").eq("device_id", device.id).single();
    if (error) throw new Error("Purchase identity unavailable");
    return { customerID: data.customer_id };
  }
  if (action === "verify_purchase") {
    const { error } = await db.rpc("pc_access_request_purchase_refresh", { p_owner: device.id });
    if (error) throw new Error("Purchase refresh unavailable");
    await refreshOwner(db, device.id, secret);
    const { data: owner, error: ownerError } = await db.from("pc_access_owners")
      .select("purchase_state,verified_at,purchase_until,lifetime").eq("device_id", device.id).single();
    if (ownerError) throw new Error("Purchase verification unavailable");
    return { access: await accessSnapshot(db, device.id), purchaseConfirmed: purchaseConfirmed(owner) };
  }
  const { data: pair, error: pairError } = await db.from("pc_access_pairs").select("parent_id,child_id")
    .eq("family_id", device.family_id ?? "00000000-0000-0000-0000-000000000000").maybeSingle();
  if (pairError) throw new Error("Access pairing unavailable");
  if (!pair) return { access: { enforced: false } };
  if (device.id !== pair.parent_id && device.id !== pair.child_id) throw new Error("Pairing changed");
  if (action === "release_control" || action === "resume_control") {
    const { error } = await db.rpc("pc_access_release", { p_device: device.id, p_released: action === "release_control" });
    if (error) throw new Error("Cannot update control access");
  }
  // Verification only on explicit restore/purchase or the throttled status path,
  // never on each ordinary sync command. Cooldown is server enforced.
  const current = await accessSnapshot(db, device.id);
  if (!current.enforced) return { access: current };
  await refreshOwner(db, pair.parent_id, secret);
  const updated = await accessSnapshot(db, device.id);
  return { access: updated, accessChanged: current.state !== updated.state };
}
