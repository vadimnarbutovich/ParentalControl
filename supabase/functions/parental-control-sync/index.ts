import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.49.1";
import * as jose from "npm:jose@5.9.6";

type Json = Record<string, unknown>;
type ActionRequest = { action: string; payload: Json };

type RetryBatchOptions = {
  familyID?: string | null;
  maxBatch: number;
  minAgeSeconds: number;
  minRetryCount: number;
};

type FocusCommandRow = {
  id: string;
  family_id: string;
  command_type: string;
  duration_seconds: number | null;
  status: string;
  created_at: string;
  updated_at: string;
  retry_count?: number;
  error_message?: string | null;
  intent_id?: string | null;
  expires_at?: string;
};

const MAX_APNS_RETRY = 4;
const COMMAND_TTL_SECONDS = 10 * 60;
const DEFAULT_RETRY_BATCH = 6;
const DEFAULT_RETRY_MIN_AGE_SECONDS = 6;
const DEFAULT_CRON_RETRY_BATCH = 50;
const DEFAULT_CRON_RETRY_MIN_AGE_SECONDS = 10;
const CRON_SHARED_TOKEN = "pc_retry_2026_04_20_w8pJQ7mN2xL5rV9d";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const supabase = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-device-install-id, x-device-secret, x-cron-token",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const body = (await req.json()) as ActionRequest;
    const action = body?.action ?? "";
    const payload = (body?.payload ?? {}) as Json;

    if (action === "cron_retry_stuck_commands") return await cronRetryStuckCommands(req, payload);
    if (action === "register_device") return await registerDevice(payload);

    const authed = await requireDevice(req);

    switch (action) {
      case "generate_pairing_code":
        return await generatePairingCode(authed.deviceId);
      case "join_pairing_code":
        return await joinPairingCode(authed.deviceId, payload);
      case "update_apns_token":
        return await updateApnsToken(authed.deviceId, payload);
      case "queue_focus_command":
        return await queueFocusCommand(authed.deviceId, payload);
      case "replace_focus_command":
        return await replaceFocusCommand(authed.deviceId, payload);
      case "fetch_pending_commands":
        return await fetchPendingCommands(authed.deviceId);
      case "fetch_desired_focus_state":
        return await fetchDesiredFocusState(authed.deviceId);
      case "fetch_command_status":
        return await fetchCommandStatus(authed.deviceId, payload);
      case "retry_stuck_commands":
        return await retryStuckCommands(authed.deviceId, payload);
      case "fetch_link_health":
        return await fetchLinkHealth(authed.deviceId);
      case "ack_command":
        return await ackCommand(authed.deviceId, payload);
      case "upsert_child_day_stats":
        return await upsertChildDayStats(authed.deviceId, payload);
      case "fetch_child_day_stats":
        return await fetchChildDayStats(authed.deviceId, payload);
      case "update_child_runtime":
        return await updateChildRuntime(authed.deviceId, payload);
      case "fetch_parent_snapshot":
        return await fetchParentSnapshot(authed.deviceId);
      case "request_child_location":
        return await requestChildLocation(authed.deviceId);
      case "update_child_location":
        return await updateChildLocation(authed.deviceId, payload);
      case "fetch_child_location":
        return await fetchChildLocation(authed.deviceId);
      default:
        return errorResponse("Unknown action", 400);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unexpected server error";
    return errorResponse(message, 500);
  }
});

async function registerDevice(payload: Json): Promise<Response> {
  const installID = asString(payload.installID);
  const role = asString(payload.role);
  if (!installID || (role !== "parent" && role !== "child")) return errorResponse("installID and role are required", 400);

  const { data: existing, error: existingError } = await supabase
    .from("devices")
    .select("id, device_secret, family_id")
    .eq("install_id", installID)
    .maybeSingle();
  if (existingError) return errorResponse(existingError.message, 400);

  if (existing) {
    const pairingState = existing.family_id ? await fetchPairingState(existing.family_id) : null;
    return okResponse({ deviceSecret: existing.device_secret, pairingState });
  }

  const deviceSecret = crypto.randomUUID() + crypto.randomUUID();
  const { error: insertError } = await supabase
    .from("devices")
    .insert({ install_id: installID, role, device_secret: deviceSecret });
  if (insertError) return errorResponse(insertError.message, 400);

  return okResponse({ deviceSecret, pairingState: null });
}

async function generatePairingCode(deviceId: string): Promise<Response> {
  const device = await getDevice(deviceId);
  if (device.role !== "parent") return errorResponse("Only parent device can generate pairing code", 403);

  const code = generateCode();
  let familyID = device.family_id as string | null;
  if (!familyID) {
    const { data: family, error } = await supabase
      .from("families")
      .insert({ pairing_code: code, status: "active" })
      .select("id")
      .single();
    if (error || !family) return errorResponse(error?.message ?? "Failed to create family", 400);
    familyID = family.id;
    const { error: bindError } = await supabase.from("devices").update({ family_id: familyID }).eq("id", deviceId);
    if (bindError) return errorResponse(bindError.message, 400);
  } else {
    const { error: updateError } = await supabase
      .from("families")
      .update({ pairing_code: code, status: "active" })
      .eq("id", familyID);
    if (updateError) return errorResponse(updateError.message, 400);
  }

  return okResponse(await fetchPairingState(familyID));
}

async function joinPairingCode(deviceId: string, payload: Json): Promise<Response> {
  const code = asString(payload.pairingCode)?.toUpperCase();
  if (!code) return errorResponse("pairingCode is required", 400);

  const device = await getDevice(deviceId);
  if (device.role !== "child") return errorResponse("Only child device can join pairing code", 403);

  const { data: family, error: familyError } = await supabase
    .from("families")
    .select("id")
    .eq("pairing_code", code)
    .eq("status", "active")
    .single();
  if (familyError || !family) return errorResponse("Pairing code not found", 404);

  const { data: childInFamily, error: childFamilyError } = await supabase
    .from("devices")
    .select("id")
    .eq("family_id", family.id)
    .eq("role", "child")
    .neq("id", deviceId)
    .maybeSingle();
  if (childFamilyError) return errorResponse(childFamilyError.message, 400);
  if (childInFamily) return errorResponse("Family already has a child device", 409);

  const { error: bindError } = await supabase.from("devices").update({ family_id: family.id }).eq("id", deviceId);
  if (bindError) return errorResponse(bindError.message, 400);

  return okResponse(await fetchPairingState(family.id));
}

async function updateApnsToken(deviceId: string, payload: Json): Promise<Response> {
  const token = asString(payload.apnsToken);
  if (!token) return errorResponse("apnsToken is required", 400);
  const normalized = token.replace(/\s+/g, "").trim();
  const { error } = await supabase.from("devices").update({ apns_token: normalized }).eq("id", deviceId);
  if (error) return errorResponse(error.message, 400);
  return okResponse({ ok: true });
}

async function queueFocusCommand(deviceId: string, payload: Json): Promise<Response> {
  const commandType = asString(payload.commandType);
  const durationSeconds = asNumber(payload.durationSeconds);
  const intentID = asUUIDString(payload.intentID);
  if (commandType !== "start_focus" && commandType !== "end_focus") return errorResponse("Invalid command type", 400);

  const parentDevice = await getDevice(deviceId);
  if (parentDevice.role !== "parent" || !parentDevice.family_id) return errorResponse("Parent device is not paired", 403);

  const { data: child, error: childError } = await supabase
    .from("devices")
    .select("id, apns_token")
    .eq("family_id", parentDevice.family_id)
    .eq("role", "child")
    .single();
  if (childError || !child) return errorResponse("Child device is not linked", 404);

  await upsertDesiredFocusState(parentDevice.family_id, parentDevice.id, commandType, durationSeconds);

  return await createAndDispatchFocusCommand({
    familyID: parentDevice.family_id,
    parentDeviceID: parentDevice.id,
    childDeviceID: child.id,
    childApnsToken: child.apns_token,
    commandType,
    durationSeconds,
    intentID,
  });
}

async function replaceFocusCommand(deviceId: string, payload: Json): Promise<Response> {
  const commandType = asString(payload.commandType);
  const durationSeconds = asNumber(payload.durationSeconds);
  const intentID = asUUIDString(payload.intentID);
  if (commandType !== "start_focus" && commandType !== "end_focus") return errorResponse("Invalid command type", 400);
  if (!intentID) return errorResponse("intentID is required", 400);

  const parentDevice = await getDevice(deviceId);
  if (parentDevice.role !== "parent" || !parentDevice.family_id) return errorResponse("Parent device is not paired", 403);

  const { data: child, error: childError } = await supabase
    .from("devices")
    .select("id, apns_token")
    .eq("family_id", parentDevice.family_id)
    .eq("role", "child")
    .single();
  if (childError || !child) return errorResponse("Child device is not linked", 404);

  await upsertDesiredFocusState(parentDevice.family_id, parentDevice.id, commandType, durationSeconds);

  const hasToken = !!asString(child.apns_token);
  const { data: rpcData, error: rpcError } = await supabase.rpc("replace_focus_command_atomic", {
    p_family_id: parentDevice.family_id,
    p_parent_device_id: parentDevice.id,
    p_child_device_id: child.id,
    p_command_type: commandType,
    p_duration_seconds: durationSeconds,
    p_intent_id: intentID,
    p_has_token: hasToken,
  });
  if (rpcError) return errorResponse(rpcError.message, 400);

  const command = (Array.isArray(rpcData) ? rpcData[0] : rpcData) as FocusCommandRow | null;
  if (!command) return errorResponse("Failed to queue command", 400);

  if (hasToken && command.status === "sent" && Number(command.retry_count ?? 0) === 0 && child.apns_token) {
    await dispatchInitialPush(String(command.id), String(child.apns_token), commandType, durationSeconds, 0);
  }

  return okResponse(mapCommandForClient(command));
}

async function fetchPendingCommands(deviceId: string): Promise<Response> {
  const device = await getDevice(deviceId);
  if (device.role !== "child") return errorResponse("Only child can fetch commands", 403);

  await expireStalePendingCommands(device.family_id);
  const nowIso = new Date().toISOString();
  const { data, error } = await supabase
    .from("focus_commands")
    .select("id, family_id, command_type, duration_seconds, status, created_at, updated_at")
    .eq("target_device_id", deviceId)
    .in("status", ["queued", "sent", "delivered"])
    .gt("expires_at", nowIso)
    .order("created_at", { ascending: true })
    .limit(20);
  if (error) return errorResponse(error.message, 400);

  return okResponse((data ?? []).map((row) => mapCommandForClient(row as FocusCommandRow)));
}

async function fetchDesiredFocusState(deviceId: string): Promise<Response> {
  const device = await getDevice(deviceId);
  if (!device.family_id) return errorResponse("Device is not paired", 403);

  const { data, error } = await supabase
    .from("family_focus_desired_state")
    .select("should_focus_active, desired_duration_seconds, updated_at")
    .eq("family_id", device.family_id)
    .maybeSingle();
  if (error) return errorResponse(error.message, 400);

  return okResponse({
    shouldFocusActive: data?.should_focus_active ?? false,
    durationSeconds: data?.desired_duration_seconds ?? null,
    updatedAt: data?.updated_at ?? new Date(0).toISOString(),
  });
}

async function fetchCommandStatus(deviceId: string, payload: Json): Promise<Response> {
  const commandID = asString(payload.commandID);
  if (!commandID) return errorResponse("commandID is required", 400);

  const requester = await getDevice(deviceId);
  if (!requester.family_id) return errorResponse("Device is not paired", 403);

  const { data, error } = await supabase
    .from("focus_commands")
    .select("id, command_type, status, error_message, created_at, updated_at, applied_at, family_id, requested_by_device_id")
    .eq("id", commandID)
    .maybeSingle();
  if (error) return errorResponse(error.message, 400);
  if (!data) return okResponse(null);

  if (data.family_id !== requester.family_id) return errorResponse("Forbidden", 403);
  if (requester.role === "parent" && data.requested_by_device_id !== requester.id) return errorResponse("Forbidden", 403);

  return okResponse({
    id: data.id,
    commandType: data.command_type,
    status: data.status,
    errorMessage: data.error_message,
    createdAt: data.created_at,
    updatedAt: data.updated_at,
    appliedAt: data.applied_at,
  });
}

async function retryStuckCommands(deviceId: string, payload: Json): Promise<Response> {
  const requester = await getDevice(deviceId);
  if (requester.role !== "parent" || !requester.family_id) return errorResponse("Only paired parent can trigger retries", 403);

  const maxBatch = clampInt(asNumber(payload.maxBatch), DEFAULT_RETRY_BATCH, 1, 20);
  const minAgeSeconds = clampInt(asNumber(payload.minAgeSeconds), DEFAULT_RETRY_MIN_AGE_SECONDS, 3, 120);

  const result = await retryStuckCommandsBatch({
    familyID: requester.family_id,
    maxBatch,
    minAgeSeconds,
    minRetryCount: 0,
  });
  return okResponse(result);
}

async function cronRetryStuckCommands(req: Request, payload: Json): Promise<Response> {
  const token = req.headers.get("x-cron-token") ?? "";
  if (token !== CRON_SHARED_TOKEN) return errorResponse("Unauthorized", 401);

  const maxBatch = clampInt(asNumber(payload.maxBatch), DEFAULT_CRON_RETRY_BATCH, 1, 200);
  const minAgeSeconds = clampInt(asNumber(payload.minAgeSeconds), DEFAULT_CRON_RETRY_MIN_AGE_SECONDS, 5, 600);

  const result = await retryStuckCommandsBatch({
    familyID: null,
    maxBatch,
    minAgeSeconds,
    minRetryCount: 0,
  });
  return okResponse(result);
}

async function retryStuckCommandsBatch(options: RetryBatchOptions): Promise<{ retried: number; failed: number; skipped: number }> {
  await expireStalePendingCommands(options.familyID ?? null);

  const nowIso = new Date().toISOString();
  const cutoffIso = new Date(Date.now() - options.minAgeSeconds * 1000).toISOString();

  let query = supabase
    .from("focus_commands")
    .select("id, target_device_id, command_type, duration_seconds, status, retry_count, family_id, last_push_attempt_at")
    .in("status", ["queued", "sent"])
    .gt("expires_at", nowIso)
    .or(`last_push_attempt_at.is.null,last_push_attempt_at.lte.${cutoffIso}`)
    .order("created_at", { ascending: true })
    .limit(options.maxBatch);

  if (options.familyID) query = query.eq("family_id", options.familyID);
  if (options.minRetryCount > 0) query = query.gte("retry_count", options.minRetryCount);

  const { data: stuck, error: stuckError } = await query;
  if (stuckError) throw new Error(stuckError.message);

  const commands = stuck ?? [];
  if (commands.length === 0) return { retried: 0, failed: 0, skipped: 0 };

  const targetIds = [...new Set(commands.map((c) => c.target_device_id))];
  const { data: targetDevices, error: targetError } = await supabase
    .from("devices")
    .select("id, apns_token")
    .in("id", targetIds);
  if (targetError) throw new Error(targetError.message);

  const tokenByDevice = new Map<string, string>();
  for (const d of targetDevices ?? []) {
    if (asString(d.apns_token)) tokenByDevice.set(d.id, d.apns_token);
  }

  let retried = 0;
  let failed = 0;
  let skipped = 0;

  for (const command of commands) {
    const retries = Number(command.retry_count ?? 0);
    if (retries >= MAX_APNS_RETRY) {
      const { error } = await supabase
        .from("focus_commands")
        .update({ status: "failed", error_message: "max_retry_exceeded" })
        .eq("id", command.id)
        .in("status", ["queued", "sent"]);
      if (!error) failed += 1;
      continue;
    }

    const token = tokenByDevice.get(command.target_device_id);
    if (!token) {
      await supabase
        .from("focus_commands")
        .update({
          status: "queued",
          error_message: "Child APNs token missing",
          retry_count: retries + 1,
          last_push_attempt_at: new Date().toISOString(),
        })
        .eq("id", command.id)
        .in("status", ["queued", "sent"]);
      skipped += 1;
      continue;
    }

    const result = await attemptPushForCommand(
      String(command.id),
      token,
      String(command.command_type),
      command.duration_seconds,
      retries
    );
    if (result.ok) {
      retried += 1;
      continue;
    }

    skipped += 1;
    if (result.retryCount >= MAX_APNS_RETRY) {
      await supabase
        .from("focus_commands")
        .update({ status: "failed", error_message: result.error ?? "max_retry_exceeded" })
        .eq("id", command.id)
        .in("status", ["queued", "sent"]);
      failed += 1;
    }
  }

  return { retried, failed, skipped };
}

async function fetchLinkHealth(deviceId: string): Promise<Response> {
  const parent = await getDevice(deviceId);
  if (parent.role !== "parent" || !parent.family_id) return errorResponse("Only paired parent can fetch link health", 403);

  await expireStalePendingCommands(parent.family_id);

  const now = Date.now();
  const nowIso = new Date(now).toISOString();
  const { data: pendingRows, error: pendingError } = await supabase
    .from("focus_commands")
    .select("id, created_at")
    .eq("family_id", parent.family_id)
    .in("status", ["queued", "sent", "delivered"])
    .gt("expires_at", nowIso)
    .order("created_at", { ascending: true })
    .limit(50);
  if (pendingError) return errorResponse(pendingError.message, 400);

  const { data: runtime, error: runtimeError } = await supabase
    .from("child_runtime_state")
    .select("updated_at")
    .eq("family_id", parent.family_id)
    .maybeSingle();
  if (runtimeError) return errorResponse(runtimeError.message, 400);

  const { count: recentFailures, error: failuresError } = await supabase
    .from("focus_commands")
    .select("id", { count: "exact", head: true })
    .eq("family_id", parent.family_id)
    .eq("status", "failed")
    .gte("updated_at", new Date(now - 30 * 60 * 1000).toISOString());
  if (failuresError) return errorResponse(failuresError.message, 400);

  const oldestPendingAt = pendingRows?.[0]?.created_at ? Date.parse(pendingRows[0].created_at) : null;
  const childLastSeenAt = runtime?.updated_at ? Date.parse(runtime.updated_at) : null;

  return okResponse({
    pendingCommands: pendingRows?.length ?? 0,
    oldestPendingAgeSeconds: oldestPendingAt ? Math.max(0, Math.floor((now - oldestPendingAt) / 1000)) : null,
    childLastSeenAgeSeconds: childLastSeenAt ? Math.max(0, Math.floor((now - childLastSeenAt) / 1000)) : null,
    childLikelyOnline: childLastSeenAt ? (now - childLastSeenAt) <= 45_000 : false,
    recentFailedCommands30m: recentFailures ?? 0,
  });
}

async function ackCommand(deviceId: string, payload: Json): Promise<Response> {
  const commandID = asString(payload.commandID);
  const status = asString(payload.status);
  const errorMessage = asString(payload.errorMessage);
  if (!commandID || !status) return errorResponse("commandID and status are required", 400);

  const { data: command, error: commandError } = await supabase
    .from("focus_commands")
    .select("id, target_device_id")
    .eq("id", commandID)
    .single();
  if (commandError || !command) return errorResponse("Command not found", 404);
  if (command.target_device_id !== deviceId) return errorResponse("Forbidden", 403);

  const patch: Record<string, unknown> = { status, error_message: errorMessage || null };
  if (status === "applied") patch.applied_at = new Date().toISOString();

  const { error } = await supabase.from("focus_commands").update(patch).eq("id", commandID);
  if (error) return errorResponse(error.message, 400);
  return okResponse({ ok: true });
}

async function upsertChildDayStats(deviceId: string, payload: Json): Promise<Response> {
  const device = await getDevice(deviceId);
  if (device.role !== "child" || !device.family_id) return errorResponse("Only paired child can sync stats", 403);

  const dayStartISO = asString(payload.dayStartISO);
  if (!dayStartISO) return errorResponse("dayStartISO is required", 400);

  const row = {
    family_id: device.family_id,
    child_device_id: device.id,
    day_start: dayStartISO,
    steps: asNumber(payload.steps) ?? 0,
    earned_seconds: asNumber(payload.earnedSeconds) ?? 0,
    spent_seconds: asNumber(payload.spentSeconds) ?? 0,
    push_ups: asNumber(payload.pushUps) ?? 0,
    squats: asNumber(payload.squats) ?? 0,
    focus_session_total_seconds: asNumber(payload.focusSessionTotalSeconds) ?? 0,
  };

  const { error } = await supabase.from("daily_stats_snapshots").upsert(row, { onConflict: "child_device_id,day_start" });
  if (error) return errorResponse(error.message, 400);
  return okResponse({ ok: true });
}

async function fetchChildDayStats(deviceId: string, payload: Json): Promise<Response> {
  const parentDevice = await getDevice(deviceId);
  if (parentDevice.role !== "parent" || !parentDevice.family_id) return errorResponse("Only paired parent can read child stats", 403);

  const dayStartISO = asString(payload.dayStartISO);
  if (!dayStartISO) return errorResponse("dayStartISO is required", 400);

  const { data: child, error: childError } = await supabase
    .from("devices")
    .select("id")
    .eq("family_id", parentDevice.family_id)
    .eq("role", "child")
    .single();
  if (childError || !child) return okResponse(null);

  const { data, error } = await supabase
    .from("daily_stats_snapshots")
    .select("day_start, steps, earned_seconds, spent_seconds, push_ups, squats, focus_session_total_seconds")
    .eq("child_device_id", child.id)
    .eq("day_start", dayStartISO)
    .maybeSingle();
  if (error) return errorResponse(error.message, 400);
  if (!data) return okResponse(null);

  return okResponse({
    dayStartISO: data.day_start,
    steps: data.steps,
    earnedSeconds: data.earned_seconds,
    spentSeconds: data.spent_seconds,
    pushUps: data.push_ups,
    squats: data.squats,
    focusSessionTotalSeconds: data.focus_session_total_seconds,
  });
}

async function updateChildRuntime(deviceId: string, payload: Json): Promise<Response> {
  const child = await getDevice(deviceId);
  if (child.role !== "child" || !child.family_id) return errorResponse("Only paired child can update runtime", 403);

  const isFocusActive = asBool(payload.isFocusActive);
  const focusEndsAt = asString(payload.focusEndsAt);

  const { error } = await supabase
    .from("child_runtime_state")
    .upsert({
      family_id: child.family_id,
      child_device_id: child.id,
      is_focus_active: isFocusActive,
      focus_ends_at: focusEndsAt || null,
      updated_at: new Date().toISOString(),
    }, { onConflict: "family_id" });
  if (error) return errorResponse(error.message, 400);
  return okResponse({ ok: true });
}

async function fetchParentSnapshot(deviceId: string): Promise<Response> {
  const parent = await getDevice(deviceId);
  if (parent.role !== "parent" || !parent.family_id) return errorResponse("Only paired parent can fetch snapshot", 403);

  const { data, error } = await supabase
    .from("child_runtime_state")
    .select("is_focus_active, focus_ends_at, updated_at")
    .eq("family_id", parent.family_id)
    .maybeSingle();
  if (error) return errorResponse(error.message, 400);

  return okResponse({
    runtime: {
      isFocusActive: data?.is_focus_active ?? false,
      focusEndsAt: data?.focus_ends_at ?? null,
      lastUpdatedAt: data?.updated_at ?? new Date(0).toISOString(),
    },
  });
}

// === Location actions ===

async function requestChildLocation(deviceId: string): Promise<Response> {
  // Parent asks for a fresh GPS fix from the paired child via APNs alert push.
  // We re-use the existing focus_commands table with a new command_type, so
  // delivery, retry, expiration, NSE — everything is identical to focus commands.
  const parentDevice = await getDevice(deviceId);
  if (parentDevice.role !== "parent" || !parentDevice.family_id) {
    return errorResponse("Parent device is not paired", 403);
  }

  const { data: child, error: childError } = await supabase
    .from("devices")
    .select("id, apns_token")
    .eq("family_id", parentDevice.family_id)
    .eq("role", "child")
    .single();
  if (childError || !child) return errorResponse("Child device is not linked", 404);

  return await createAndDispatchFocusCommand({
    familyID: parentDevice.family_id,
    parentDeviceID: parentDevice.id,
    childDeviceID: child.id,
    childApnsToken: child.apns_token,
    commandType: "request_location",
    durationSeconds: null,
    intentID: null,
  });
}

async function updateChildLocation(deviceId: string, payload: Json): Promise<Response> {
  const child = await getDevice(deviceId);
  if (child.role !== "child" || !child.family_id) return errorResponse("Only paired child can update location", 403);

  const latitude = asNumber(payload.latitude);
  const longitude = asNumber(payload.longitude);
  const horizontalAccuracy = asNumber(payload.horizontalAccuracy);
  const capturedAtISO = asString(payload.capturedAtISO) ?? new Date().toISOString();

  if (latitude === null || longitude === null) return errorResponse("latitude and longitude are required", 400);
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return errorResponse("Invalid coordinates", 400);

  const { error } = await supabase
    .from("child_location_state")
    .upsert({
      family_id: child.family_id,
      child_device_id: child.id,
      latitude,
      longitude,
      horizontal_accuracy: horizontalAccuracy ?? null,
      captured_at: capturedAtISO,
      updated_at: new Date().toISOString(),
    }, { onConflict: "family_id" });
  if (error) return errorResponse(error.message, 400);
  return okResponse({ ok: true });
}

async function fetchChildLocation(deviceId: string): Promise<Response> {
  const parent = await getDevice(deviceId);
  if (parent.role !== "parent" || !parent.family_id) return errorResponse("Only paired parent can fetch location", 403);

  const { data, error } = await supabase
    .from("child_location_state")
    .select("latitude, longitude, horizontal_accuracy, captured_at, updated_at")
    .eq("family_id", parent.family_id)
    .maybeSingle();
  if (error) return errorResponse(error.message, 400);
  if (!data) return okResponse(null);

  return okResponse({
    latitude: data.latitude,
    longitude: data.longitude,
    horizontalAccuracy: data.horizontal_accuracy ?? null,
    capturedAtISO: data.captured_at,
    updatedAtISO: data.updated_at,
  });
}

// === Helpers ===

async function upsertDesiredFocusState(
  familyID: string,
  updaterDeviceID: string,
  commandType: string,
  durationSeconds: number | null
): Promise<void> {
  const shouldActive = commandType === "start_focus";
  await supabase
    .from("family_focus_desired_state")
    .upsert({
      family_id: familyID,
      should_focus_active: shouldActive,
      desired_duration_seconds: shouldActive ? durationSeconds : null,
      updated_by_device_id: updaterDeviceID,
      updated_at: new Date().toISOString(),
    }, { onConflict: "family_id" });
}

async function expireStalePendingCommands(familyID: string | null | undefined): Promise<void> {
  let query = supabase
    .from("focus_commands")
    .update({ status: "failed", error_message: "expired_ttl" })
    .in("status", ["queued", "sent", "delivered"])
    .lte("expires_at", new Date().toISOString());
  if (familyID) query = query.eq("family_id", familyID);
  await query;
}

async function createAndDispatchFocusCommand(args: {
  familyID: string;
  parentDeviceID: string;
  childDeviceID: string;
  childApnsToken: string | null;
  commandType: string;
  durationSeconds: number | null;
  intentID: string | null;
}): Promise<Response> {
  if (args.intentID) {
    const { data: existing, error: existingError } = await supabase
      .from("focus_commands")
      .select("id, family_id, command_type, duration_seconds, status, created_at, updated_at, retry_count, error_message, intent_id")
      .eq("requested_by_device_id", args.parentDeviceID)
      .eq("intent_id", args.intentID)
      .maybeSingle();
    if (existingError) return errorResponse(existingError.message, 400);
    if (existing) return okResponse(mapCommandForClient(existing as FocusCommandRow));
  }

  const hasToken = !!asString(args.childApnsToken);
  const nowIso = new Date().toISOString();
  const expiresAt = new Date(Date.now() + COMMAND_TTL_SECONDS * 1000).toISOString();
  const { data: command, error: commandError } = await supabase
    .from("focus_commands")
    .insert({
      family_id: args.familyID,
      requested_by_device_id: args.parentDeviceID,
      target_device_id: args.childDeviceID,
      command_type: args.commandType,
      duration_seconds: args.durationSeconds,
      status: hasToken ? "sent" : "queued",
      error_message: hasToken ? null : "Child APNs token missing",
      retry_count: 0,
      last_push_attempt_at: hasToken ? nowIso : null,
      intent_id: args.intentID,
      expires_at: expiresAt,
    })
    .select("id, family_id, command_type, duration_seconds, status, created_at, updated_at, retry_count, error_message, intent_id")
    .single();
  if (commandError || !command) return errorResponse(commandError?.message ?? "Failed to queue command", 400);

  if (hasToken && args.childApnsToken) {
    await dispatchInitialPush(String(command.id), String(args.childApnsToken), args.commandType, args.durationSeconds, 0);
  }

  return okResponse(mapCommandForClient(command as FocusCommandRow));
}

async function requireDevice(req: Request): Promise<{ deviceId: string }> {
  const installID = req.headers.get("x-device-install-id") ?? "";
  const secret = req.headers.get("x-device-secret") ?? "";
  if (!installID || !secret) throw new Error("Missing device credentials");

  const { data, error } = await supabase
    .from("devices")
    .select("id, device_secret")
    .eq("install_id", installID)
    .maybeSingle();
  if (error || !data) throw new Error("Device is not registered");
  if (data.device_secret !== secret) throw new Error("Invalid device credentials");
  return { deviceId: data.id };
}

async function fetchPairingState(familyID: string) {
  const { data: family, error: familyError } = await supabase
    .from("families")
    .select("id, pairing_code")
    .eq("id", familyID)
    .single();
  if (familyError || !family) throw new Error(familyError?.message ?? "Family not found");

  const { data: devices, error: devicesError } = await supabase
    .from("devices")
    .select("id, role")
    .eq("family_id", familyID);
  if (devicesError) throw new Error(devicesError.message);

  const parent = (devices ?? []).find((d) => d.role === "parent");
  const child = (devices ?? []).find((d) => d.role === "child");
  return {
    familyID,
    pairingCode: family.pairing_code,
    parentDeviceID: parent?.id ?? null,
    childDeviceID: child?.id ?? null,
    linkedAt: new Date().toISOString(),
  };
}

async function getDevice(deviceId: string): Promise<{ id: string; role: string; family_id: string | null }> {
  const { data, error } = await supabase
    .from("devices")
    .select("id, role, family_id")
    .eq("id", deviceId)
    .single();
  if (error || !data) throw new Error(error?.message ?? "Device not found");
  return data as { id: string; role: string; family_id: string | null };
}

async function dispatchInitialPush(
  commandID: string,
  token: string,
  commandType: string,
  durationSeconds: number | null,
  retryCount: number
): Promise<void> {
  await attemptPushForCommand(commandID, token, commandType, durationSeconds, retryCount);
}

async function attemptPushForCommand(
  commandID: string,
  token: string,
  commandType: string,
  durationSeconds: number | null,
  retryCount: number
): Promise<{ ok: boolean; retryCount: number; error?: string }> {
  const nextRetryCount = retryCount + 1;
  const nowIso = new Date().toISOString();
  try {
    await sendApnsAlert(token, commandID, commandType, durationSeconds);
    await supabase
      .from("focus_commands")
      .update({
        status: "sent",
        error_message: null,
        retry_count: nextRetryCount,
        last_push_attempt_at: nowIso,
      })
      .eq("id", commandID)
      .in("status", ["queued", "sent"]);
    return { ok: true, retryCount: nextRetryCount };
  } catch (pushError) {
    const message = pushError instanceof Error ? pushError.message : "push send failed";
    await supabase
      .from("focus_commands")
      .update({
        status: "queued",
        error_message: message,
        retry_count: nextRetryCount,
        last_push_attempt_at: nowIso,
      })
      .eq("id", commandID)
      .in("status", ["queued", "sent"]);
    return { ok: false, retryCount: nextRetryCount, error: message };
  }
}

function mapCommandForClient(command: FocusCommandRow) {
  return {
    id: command.id,
    familyID: command.family_id,
    commandType: command.command_type,
    durationSeconds: command.duration_seconds,
    status: command.status,
    createdAt: command.created_at,
    updatedAt: command.updated_at,
  };
}

function generateCode(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let result = "";
  for (let i = 0; i < 6; i += 1) result += alphabet[Math.floor(Math.random() * alphabet.length)];
  return result;
}

async function apnsAuthHeaders(): Promise<{ host: string; topic: string; authorization: string }> {
  const keyID = Deno.env.get("APNS_KEY_ID");
  const teamID = Deno.env.get("APNS_TEAM_ID");
  const p8Raw = Deno.env.get("APNS_PRIVATE_KEY");
  const topic = Deno.env.get("APNS_TOPIC") ?? "mycompny.ParentalControl";
  const useSandbox = (Deno.env.get("APNS_USE_SANDBOX") ?? "true").toLowerCase() === "true";
  const host = useSandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  if (!keyID || !teamID || !p8Raw) throw new Error("APNs credentials are not configured");

  const p8 = p8Raw.replace(/\\n/g, "\n");
  const privateKey = await jose.importPKCS8(p8, "ES256");
  const jwt = await new jose.SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyID })
    .setIssuer(teamID)
    .setIssuedAt()
    .setExpirationTime("20m")
    .sign(privateKey);
  return { host, topic, authorization: `bearer ${jwt}` };
}

function commandLocalizedAlert(commandType: string, durationSeconds: number | null): { title: string; body: string } {
  switch (commandType) {
    case "start_focus":
      return { title: "ParentalControl", body: "Родитель заблокировал приложения" };
    case "end_focus":
      return { title: "ParentalControl", body: "Родитель разблокировал приложения" };
    case "reset_earned_balance":
      return { title: "ParentalControl", body: "Родитель забрал заработанное время" };
    case "add_earned_seconds": {
      const seconds = durationSeconds ?? 0;
      const minutes = Math.max(1, Math.round(seconds / 60));
      return { title: "ParentalControl", body: `Родитель добавил ${minutes} мин времени` };
    }
    case "request_location":
      return { title: "ParentalControl", body: "Родитель запросил местоположение" };
    default:
      return { title: "ParentalControl", body: "Получена команда от родителя" };
  }
}

async function sendApnsAlert(
  tokenRaw: string,
  commandID: string,
  commandType: string,
  durationSeconds: number | null
): Promise<void> {
  const auth = await apnsAuthHeaders();
  const token = tokenRaw.replace(/\s+/g, "");
  const localized = commandLocalizedAlert(commandType, durationSeconds);
  // Уровень приоритета визуальной части. Для request_location используем `passive` —
  // ребёнок не видит баннер на Lock Screen и не слышит звук, но пробуждение приложения,
  // запуск NSE и доставка идут АБСОЛЮТНО ТАК ЖЕ как у time-sensitive: APNs обрабатывает
  // alert с priority=10 одинаково независимо от interruption-level. Это поле влияет
  // только на визуальное представление в iOS.
  const isSilentCommand = commandType === "request_location";
  const interruptionLevel = isSilentCommand ? "passive" : "time-sensitive";
  const aps: Record<string, unknown> = {
    alert: {
      title: localized.title,
      body: localized.body,
    },
    "mutable-content": 1,
    "content-available": 1,
    "interruption-level": interruptionLevel,
  };
  if (!isSilentCommand) {
    aps.sound = "default";
  }
  const payload: Record<string, unknown> = {
    aps,
    command_id: commandID,
    command_type: commandType,
    duration_seconds: durationSeconds,
  };
  const expirationEpoch = Math.floor(Date.now() / 1000) + COMMAND_TTL_SECONDS;
  const res = await fetch(`https://${auth.host}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: auth.authorization,
      "apns-topic": auth.topic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": String(expirationEpoch),
      "apns-collapse-id": `cmd-${commandID}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`APNs error ${res.status}: ${text}`);
}

function clampInt(value: number | null, fallback: number, min: number, max: number): number {
  if (value === null) return fallback;
  const rounded = Math.round(value);
  return Math.min(Math.max(rounded, min), max);
}

function asString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function asUUIDString(value: unknown): string | null {
  const raw = asString(value);
  if (!raw) return null;
  return /^[0-9a-fA-F-]{36}$/.test(raw) ? raw.toLowerCase() : null;
}

function asNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim().length > 0) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function asBool(value: unknown): boolean {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") return value.toLowerCase() === "true";
  return false;
}

function okResponse(payload: unknown): Response {
  return new Response(JSON.stringify(payload), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

function errorResponse(message: string, status = 400): Response {
  return new Response(JSON.stringify({ error: message }), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}
