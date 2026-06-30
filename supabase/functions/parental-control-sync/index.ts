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
    if (action === "cron_evaluate_block_schedules") return await cronEvaluateBlockSchedules(req);
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
      case "list_block_schedules":
        return await listBlockSchedules(authed.deviceId);
      case "upsert_block_schedule":
        return await upsertBlockSchedule(authed.deviceId, payload);
      case "delete_block_schedule":
        return await deleteBlockSchedule(authed.deviceId, payload);
      case "set_parent_pin":
        return await setParentPin(authed.deviceId, payload);
      case "clear_parent_pin":
        return await clearParentPin(authed.deviceId);
      case "fetch_parent_pin":
        return await fetchParentPin(authed.deviceId);
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

async function cronEvaluateBlockSchedules(req: Request): Promise<Response> {
  const token = req.headers.get("x-cron-token") ?? "";
  if (token !== CRON_SHARED_TOKEN) return errorResponse("Unauthorized", 401);

  type ScheduleRow = {
    id: string;
    family_id: string;
    name: string;
    start_hour: number;
    start_minute: number;
    end_hour: number;
    end_minute: number;
    weekdays: number[];
    is_enabled: boolean;
    is_currently_active: boolean;
    timezone_identifier: string;
    deleted_at: string | null;
  };

  const { data: rows, error } = await supabase
    .from("family_block_schedules")
    .select("id, family_id, name, start_hour, start_minute, end_hour, end_minute, weekdays, is_enabled, is_currently_active, timezone_identifier, deleted_at");
  if (error) return errorResponse(error.message, 400);

  const now = new Date();
  let started = 0;
  let ended = 0;
  let unchanged = 0;
  let pushFailures = 0;

  const childCache = new Map<string, { id: string; apns_token: string | null } | null>();
  const parentCache = new Map<string, string | null>();

  for (const r of (rows ?? []) as ScheduleRow[]) {
    const targetActive = (r.deleted_at == null && r.is_enabled)
      ? isScheduleActiveAt(r, now)
      : false;
    if (targetActive === r.is_currently_active) {
      unchanged += 1;
      continue;
    }
    const isActive = targetActive;

    if (!childCache.has(r.family_id)) {
      const { data: child } = await supabase
        .from("devices")
        .select("id, apns_token")
        .eq("family_id", r.family_id)
        .eq("role", "child")
        .maybeSingle();
      childCache.set(r.family_id, child ?? null);
    }
    if (!parentCache.has(r.family_id)) {
      const { data: parent } = await supabase
        .from("devices")
        .select("id")
        .eq("family_id", r.family_id)
        .eq("role", "parent")
        .maybeSingle();
      parentCache.set(r.family_id, parent?.id ?? null);
    }
    const child = childCache.get(r.family_id) ?? null;
    const parentID = parentCache.get(r.family_id) ?? null;

    const { error: updateError } = await supabase
      .from("family_block_schedules")
      .update({
        is_currently_active: isActive,
        last_state_change_at: now.toISOString(),
      })
      .eq("id", r.id);
    if (updateError) {
      console.warn("cronEvaluateBlockSchedules: update flag failed:", updateError.message);
      continue;
    }

    if (!child || !parentID) {
      if (isActive) started += 1; else ended += 1;
      continue;
    }

    const commandType = isActive ? "schedule_started" : "schedule_ended";
    const endHHMM = `${pad2(r.end_hour)}:${pad2(r.end_minute)}`;
    try {
      await dispatchScheduleCommand({
        familyID: r.family_id,
        parentDeviceID: parentID,
        childDeviceID: child.id,
        childApnsToken: child.apns_token,
        commandType,
        scheduleID: r.id,
        scheduleName: r.name,
        endHHMM,
      });
      if (isActive) started += 1; else ended += 1;
    } catch (e) {
      pushFailures += 1;
      console.warn("cronEvaluateBlockSchedules: dispatch failed:", e instanceof Error ? e.message : String(e));
    }
  }

  return okResponse({ started, ended, unchanged, pushFailures, evaluated: rows?.length ?? 0 });
}

function isScheduleActiveAt(
  row: {
    start_hour: number;
    start_minute: number;
    end_hour: number;
    end_minute: number;
    weekdays: number[];
    timezone_identifier?: string | null;
  },
  now: Date
): boolean {
  const tz = (row.timezone_identifier && row.timezone_identifier.trim().length > 0)
    ? row.timezone_identifier
    : "UTC";
  const local = formatInTimeZone(now, tz);
  const minutesOfDay = local.hour * 60 + local.minute;
  const start = row.start_hour * 60 + row.start_minute;
  const end = row.end_hour * 60 + row.end_minute;
  const crossesMidnight = end <= start;

  const todayWD = local.weekday;
  const wdSet = new Set(row.weekdays.map((v) => Number(v)));

  if (!crossesMidnight) {
    if (!wdSet.has(todayWD)) return false;
    return minutesOfDay >= start && minutesOfDay < end;
  }

  if (minutesOfDay >= start) {
    return wdSet.has(todayWD);
  }
  if (minutesOfDay < end) {
    const ywd = todayWD === 1 ? 7 : todayWD - 1;
    return wdSet.has(ywd);
  }
  return false;
}

function formatInTimeZone(date: Date, timeZone: string): { hour: number; minute: number; weekday: number } {
  try {
    const fmt = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hour12: false,
      hour: "2-digit",
      minute: "2-digit",
      weekday: "short",
    });
    const parts = fmt.formatToParts(date);
    let hour = 0;
    let minute = 0;
    let weekday = 1;
    for (const p of parts) {
      if (p.type === "hour") hour = Number(p.value) % 24;
      else if (p.type === "minute") minute = Number(p.value);
      else if (p.type === "weekday") {
        switch (p.value) {
          case "Mon": weekday = 1; break;
          case "Tue": weekday = 2; break;
          case "Wed": weekday = 3; break;
          case "Thu": weekday = 4; break;
          case "Fri": weekday = 5; break;
          case "Sat": weekday = 6; break;
          case "Sun": weekday = 7; break;
        }
      }
    }
    return { hour, minute, weekday };
  } catch (_e) {
    const utcW = date.getUTCDay();
    return {
      hour: date.getUTCHours(),
      minute: date.getUTCMinutes(),
      weekday: utcW === 0 ? 7 : utcW,
    };
  }
}

function pad2(n: number): string {
  const s = String(Math.max(0, Math.min(99, Math.round(n))));
  return s.length === 1 ? `0${s}` : s;
}

async function dispatchScheduleCommand(args: {
  familyID: string;
  parentDeviceID: string;
  childDeviceID: string;
  childApnsToken: string | null;
  commandType: "schedule_started" | "schedule_ended";
  scheduleID: string;
  scheduleName: string;
  endHHMM: string;
}): Promise<void> {
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
      duration_seconds: null,
      status: hasToken ? "sent" : "queued",
      error_message: hasToken ? null : "Child APNs token missing",
      retry_count: 0,
      last_push_attempt_at: hasToken ? nowIso : null,
      intent_id: null,
      expires_at: expiresAt,
    })
    .select("id")
    .single();
  if (commandError || !command) {
    throw new Error(commandError?.message ?? "Failed to insert schedule command");
  }

  if (hasToken && args.childApnsToken) {
    await dispatchInitialPush(
      String(command.id),
      String(args.childApnsToken),
      args.commandType,
      null,
      0,
      { scheduleName: args.scheduleName, endHHMM: args.endHHMM },
      args.scheduleID
    );
  }
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

  // v21: возвращаем latest-by-`day_start` запись для child-устройства.
  // Раньше (v20) мы матчили по `startOfUTCDay(now())`, но child пишет `day_start` по
  // *локальному* календарю (Calendar.startOfDay → ISO в UTC, Postgres приводит к date в UTC).
  // У ребёнка в МСК (UTC+3) местная полночь = 21:00 UTC предыдущего дня → запись приходит
  // с `day_start = вчера (UTC)`, а сервер искал «сегодня (UTC)» → не находил → parent видел 0/0.
  // Подход «latest» работает во всех timezones: после midnight-reset на child он создаёт
  // новую запись с earned=0/spent=0 — она становится latest и тоже корректно отражается у parent.
  const [{ data: runtimeData, error: runtimeError }, { data: childData }] = await Promise.all([
    supabase
      .from("child_runtime_state")
      .select("is_focus_active, focus_ends_at, updated_at")
      .eq("family_id", parent.family_id)
      .maybeSingle(),
    supabase
      .from("devices")
      .select("id")
      .eq("family_id", parent.family_id)
      .eq("role", "child")
      .maybeSingle(),
  ]);
  if (runtimeError) return errorResponse(runtimeError.message, 400);

  let dailyStats: Record<string, unknown> | null = null;
  if (childData?.id) {
    const { data: statsRow } = await supabase
      .from("daily_stats_snapshots")
      .select("day_start, steps, earned_seconds, spent_seconds, push_ups, squats, focus_session_total_seconds")
      .eq("child_device_id", childData.id)
      .order("day_start", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (statsRow) {
      dailyStats = {
        dayStartISO: statsRow.day_start,
        steps: statsRow.steps ?? 0,
        earnedSeconds: statsRow.earned_seconds ?? 0,
        spentSeconds: statsRow.spent_seconds ?? 0,
        pushUps: statsRow.push_ups ?? 0,
        squats: statsRow.squats ?? 0,
        focusSessionTotalSeconds: statsRow.focus_session_total_seconds ?? 0,
      };
    }
  }

  return okResponse({
    runtime: {
      isFocusActive: runtimeData?.is_focus_active ?? false,
      focusEndsAt: runtimeData?.focus_ends_at ?? null,
      lastUpdatedAt: runtimeData?.updated_at ?? new Date(0).toISOString(),
    },
    dailyStats,
  });
}

async function requestChildLocation(deviceId: string): Promise<Response> {
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

type BlockScheduleRow = {
  id: string;
  family_id: string;
  name: string;
  icon: string;
  accent: string;
  start_hour: number;
  start_minute: number;
  end_hour: number;
  end_minute: number;
  weekdays: number[];
  is_enabled: boolean;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
  timezone_identifier: string | null;
};

function mapBlockScheduleForClient(row: BlockScheduleRow) {
  return {
    id: row.id,
    name: row.name,
    icon: row.icon,
    accent: row.accent,
    startHour: row.start_hour,
    startMinute: row.start_minute,
    endHour: row.end_hour,
    endMinute: row.end_minute,
    weekdays: row.weekdays,
    isEnabled: row.is_enabled,
    createdAtISO: row.created_at,
    updatedAtISO: row.updated_at,
    deletedAtISO: row.deleted_at,
    timezoneIdentifier: row.timezone_identifier ?? "UTC",
  };
}

async function listBlockSchedules(deviceId: string): Promise<Response> {
  const device = await getDevice(deviceId);
  if (!device.family_id) return errorResponse("Device is not paired", 403);

  const { data, error } = await supabase
    .from("family_block_schedules")
    .select("id, family_id, name, icon, accent, start_hour, start_minute, end_hour, end_minute, weekdays, is_enabled, created_at, updated_at, deleted_at, timezone_identifier")
    .eq("family_id", device.family_id)
    .is("deleted_at", null)
    .order("created_at", { ascending: true });
  if (error) return errorResponse(error.message, 400);

  const items = (data ?? []).map((row) => mapBlockScheduleForClient(row as BlockScheduleRow));
  return okResponse({ schedules: items });
}

async function upsertBlockSchedule(deviceId: string, payload: Json): Promise<Response> {
  const parent = await getDevice(deviceId);
  if (parent.role !== "parent" || !parent.family_id) return errorResponse("Only paired parent can edit schedules", 403);

  const id = asUUIDString(payload.id);
  const name = asString(payload.name);
  const icon = asString(payload.icon) ?? "calendar";
  const accent = asString(payload.accent) ?? "purple";
  const startHour = asNumber(payload.startHour);
  const startMinute = asNumber(payload.startMinute);
  const endHour = asNumber(payload.endHour);
  const endMinute = asNumber(payload.endMinute);
  const weekdaysRaw = Array.isArray(payload.weekdays) ? (payload.weekdays as unknown[]) : [];
  const isEnabled = asBool(payload.isEnabled);
  const timezoneIdentifier = asString(payload.timezoneIdentifier) ?? "UTC";

  if (!id) return errorResponse("id is required (uuid)", 400);
  if (!name) return errorResponse("name is required", 400);
  if (startHour === null || startMinute === null || endHour === null || endMinute === null) {
    return errorResponse("start/end hour and minute are required", 400);
  }
  if (startHour < 0 || startHour > 23 || endHour < 0 || endHour > 23) return errorResponse("hour out of range", 400);
  if (startMinute < 0 || startMinute > 59 || endMinute < 0 || endMinute > 59) return errorResponse("minute out of range", 400);

  const weekdays = weekdaysRaw
    .map((v) => (typeof v === "number" ? v : Number(v)))
    .filter((v) => Number.isFinite(v) && v >= 1 && v <= 7);
  if (weekdays.length === 0) return errorResponse("weekdays must contain 1..7 values", 400);

  const nowIso = new Date().toISOString();
  const { error: upsertError } = await supabase
    .from("family_block_schedules")
    .upsert({
      id,
      family_id: parent.family_id,
      name,
      icon,
      accent,
      start_hour: Math.round(startHour),
      start_minute: Math.round(startMinute),
      end_hour: Math.round(endHour),
      end_minute: Math.round(endMinute),
      weekdays,
      is_enabled: isEnabled,
      timezone_identifier: timezoneIdentifier,
      updated_at: nowIso,
      deleted_at: null,
    }, { onConflict: "id" });
  if (upsertError) return errorResponse(upsertError.message, 400);

  await notifyChildSchedulesUpdated(parent.family_id, parent.id);
  return okResponse({ ok: true });
}

async function deleteBlockSchedule(deviceId: string, payload: Json): Promise<Response> {
  const parent = await getDevice(deviceId);
  if (parent.role !== "parent" || !parent.family_id) return errorResponse("Only paired parent can delete schedules", 403);

  const id = asUUIDString(payload.id);
  if (!id) return errorResponse("id is required (uuid)", 400);

  const { error: deleteError } = await supabase
    .from("family_block_schedules")
    .update({ deleted_at: new Date().toISOString(), is_enabled: false })
    .eq("id", id)
    .eq("family_id", parent.family_id);
  if (deleteError) return errorResponse(deleteError.message, 400);

  await notifyChildSchedulesUpdated(parent.family_id, parent.id);
  return okResponse({ ok: true });
}

// MARK: Parent PIN (v22)
// Родитель задаёт 4-значный PIN в своих настройках. На устройство приходит только хэш и соль —
// исходный PIN никогда не покидает устройство, где введён. Backend хранит `parent_pin_hash` /
// `parent_pin_salt` / `parent_pin_updated_at` в `families` и отдаёт child'у через `fetch_parent_pin`.
// При изменении/удалении PIN backend выстреливает silent push wake-up (`wake_child_sync` контур,
// действие `parental-control-balance-sync.wake_child_sync`), чтобы child мгновенно подтянул кэш
// и принудительно вышел из открытого parent-режима.

async function setParentPin(deviceId: string, payload: Json): Promise<Response> {
  const parent = await getDevice(deviceId);
  if (parent.role !== "parent" || !parent.family_id) {
    return errorResponse("Only paired parent can set PIN", 403);
  }
  const pinHash = asString(payload.pinHash);
  const pinSalt = asString(payload.pinSalt);
  const pinUpdatedAtRaw = asString(payload.pinUpdatedAt);
  if (!pinHash || !pinSalt) return errorResponse("pinHash and pinSalt are required", 400);
  // Лимиты base64: SHA-256 → 32 байта → ~44 char; salt 16 байт → ~24 char. Проверяем верхнюю
  // границу, чтобы не пропускать произвольно большие строки.
  if (pinHash.length > 64 || pinSalt.length > 64) {
    return errorResponse("pinHash/pinSalt too long", 400);
  }
  const updatedAt = pinUpdatedAtRaw ? new Date(pinUpdatedAtRaw).toISOString() : new Date().toISOString();
  const { error } = await supabase
    .from("families")
    .update({
      parent_pin_hash: pinHash,
      parent_pin_salt: pinSalt,
      parent_pin_updated_at: updatedAt,
    })
    .eq("id", parent.family_id);
  if (error) return errorResponse(error.message, 400);

  await notifyChildPinUpdated(parent.family_id);
  return okResponse({ ok: true });
}

async function clearParentPin(deviceId: string): Promise<Response> {
  const parent = await getDevice(deviceId);
  if (parent.role !== "parent" || !parent.family_id) {
    return errorResponse("Only paired parent can clear PIN", 403);
  }
  const { error } = await supabase
    .from("families")
    .update({
      parent_pin_hash: null,
      parent_pin_salt: null,
      parent_pin_updated_at: new Date().toISOString(),
    })
    .eq("id", parent.family_id);
  if (error) return errorResponse(error.message, 400);

  await notifyChildPinUpdated(parent.family_id);
  return okResponse({ ok: true });
}

async function fetchParentPin(deviceId: string): Promise<Response> {
  // Допускаем оба role: parent тоже может запросить (для UI «PIN установлен»), хотя обычно
  // вызывается ребёнком. RLS-уровень — общая проверка `family_id`.
  const requester = await getDevice(deviceId);
  if (!requester.family_id) return errorResponse("Device is not paired", 403);

  const { data, error } = await supabase
    .from("families")
    .select("parent_pin_hash, parent_pin_salt, parent_pin_updated_at")
    .eq("id", requester.family_id)
    .maybeSingle();
  if (error) return errorResponse(error.message, 400);
  if (!data || !data.parent_pin_hash || !data.parent_pin_salt) return okResponse(null);

  return okResponse({
    hashBase64: data.parent_pin_hash,
    saltBase64: data.parent_pin_salt,
    updatedAtISO: data.parent_pin_updated_at ?? new Date(0).toISOString(),
  });
}

/// Шлёт ребёнку семьи silent push `child_sync_request` (тот же контур, что и `wake_child_sync`
/// в `parental-control-balance-sync` v5+) — без записи в `focus_commands`. Child получает push,
/// дёргает `refreshChildParentPinIfNeeded` и обновляет кэшированный PIN; если parent-режим был
/// открыт — клиент принудительно его закроет (в `applyParentPinFromBackend`).
async function notifyChildPinUpdated(familyID: string): Promise<void> {
  try {
    const { data: child, error: childError } = await supabase
      .from("devices")
      .select("apns_token")
      .eq("family_id", familyID)
      .eq("role", "child")
      .maybeSingle();
    if (childError) {
      console.warn("[notifyChildPinUpdated] child lookup failed:", childError.message);
      return;
    }
    if (!child || !child.apns_token) return;
    await sendApnsBackground(String(child.apns_token));
  } catch (e) {
    console.warn("[notifyChildPinUpdated] push failed:", e instanceof Error ? e.message : String(e));
  }
}

/// Минималистичный silent push (`apns-push-type: background`, payload `command_type: child_sync_request`)
/// — копия логики из `parental-control-balance-sync.sendApnsBackground`. Дублируется здесь, чтобы
/// edge `parental-control-sync` не зависел от соседней функции для PIN-сценария.
async function sendApnsBackground(tokenRaw: string): Promise<void> {
  const auth = await apnsAuthHeaders();
  const token = tokenRaw.replace(/\s+/g, "");
  const expirationEpoch = Math.floor(Date.now() / 1000) + 5 * 60;
  const payload = {
    aps: { "content-available": 1 },
    command_type: "child_sync_request",
  };
  const res = await fetch(`https://${auth.host}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: auth.authorization,
      "apns-topic": auth.topic,
      "apns-push-type": "background",
      "apns-priority": "5",
      "apns-expiration": String(expirationEpoch),
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`APNs background error ${res.status}: ${text}`);
  }
}

async function notifyChildSchedulesUpdated(familyID: string, parentDeviceID: string): Promise<void> {
  try {
    const { data: child, error: childError } = await supabase
      .from("devices")
      .select("id, apns_token")
      .eq("family_id", familyID)
      .eq("role", "child")
      .maybeSingle();
    if (childError) {
      console.warn("[notifyChildSchedulesUpdated] child lookup failed:", childError.message);
      return;
    }
    if (!child) return;

    await createAndDispatchFocusCommand({
      familyID,
      parentDeviceID,
      childDeviceID: child.id,
      childApnsToken: child.apns_token,
      commandType: "schedules_updated",
      durationSeconds: null,
      intentID: null,
    });
  } catch (e) {
    console.warn("[notifyChildSchedulesUpdated] dispatch failed:", e instanceof Error ? e.message : String(e));
  }
}

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
  retryCount: number,
  extras: ScheduleAlertExtras = {},
  scheduleID: string | null = null
): Promise<void> {
  await attemptPushForCommand(commandID, token, commandType, durationSeconds, retryCount, extras, scheduleID);
}

async function attemptPushForCommand(
  commandID: string,
  token: string,
  commandType: string,
  durationSeconds: number | null,
  retryCount: number,
  extras: ScheduleAlertExtras = {},
  scheduleID: string | null = null
): Promise<{ ok: boolean; retryCount: number; error?: string }> {
  const nextRetryCount = retryCount + 1;
  const nowIso = new Date().toISOString();
  try {
    await sendApnsAlert(token, commandID, commandType, durationSeconds, extras, scheduleID);
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

type ScheduleAlertExtras = { scheduleName?: string | null; endHHMM?: string | null };

function commandLocalizedAlert(
  commandType: string,
  durationSeconds: number | null,
  extras: ScheduleAlertExtras = {}
): { title: string; body: string } {
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
    case "schedules_updated":
      return { title: "ParentalControl", body: "Расписание обновлено" };
    case "schedule_started": {
      const name = (extras.scheduleName && extras.scheduleName.trim().length > 0)
        ? extras.scheduleName
        : "Расписание";
      const tail = extras.endHHMM ? ` (до ${extras.endHHMM})` : "";
      return { title: "ParentalControl", body: `Расписание ${name}${tail}` };
    }
    case "schedule_ended": {
      const name = (extras.scheduleName && extras.scheduleName.trim().length > 0)
        ? extras.scheduleName
        : "Расписание";
      return { title: "ParentalControl", body: `Расписание ${name} завершено` };
    }
    default:
      return { title: "ParentalControl", body: "Получена команда от родителя" };
  }
}

async function sendApnsAlert(
  tokenRaw: string,
  commandID: string,
  commandType: string,
  durationSeconds: number | null,
  extras: ScheduleAlertExtras = {},
  scheduleID: string | null = null
): Promise<void> {
  const auth = await apnsAuthHeaders();
  const token = tokenRaw.replace(/\s+/g, "");
  const localized = commandLocalizedAlert(commandType, durationSeconds, extras);
  const isSilentCommand = commandType === "request_location" || commandType === "schedules_updated";
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
  if (scheduleID) payload.schedule_id = scheduleID;
  if (extras.scheduleName) payload.schedule_name = extras.scheduleName;
  if (extras.endHHMM) payload.schedule_end_hh_mm = extras.endHHMM;
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
