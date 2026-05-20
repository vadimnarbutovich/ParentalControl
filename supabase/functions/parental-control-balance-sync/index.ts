import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.49.1";
import * as jose from "npm:jose@5.9.6";

type Json = Record<string, unknown>;
type ActionRequest = { action: string; payload: Json };

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
};

const COMMAND_TTL_SECONDS = 10 * 60;

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const supabase = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-device-install-id, x-device-secret",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const body = (await req.json()) as ActionRequest;
    const action = body?.action ?? "";
    const payload = (body?.payload ?? {}) as Json;
    const authed = await requireDevice(req);

    switch (action) {
      case "queue_balance_command":
        return await queueBalanceCommand(authed.deviceId, payload);
      case "update_child_balance":
        return await updateChildBalance(authed.deviceId, payload);
      case "fetch_child_balance":
        return await fetchChildBalance(authed.deviceId);
      case "wake_child_sync":
        // v5: parent просит «разбудить» child silent-push'ом (apns-push-type: background,
        // priority 5, без alert). Child получит payload `{ command_type: "child_sync_request" }`,
        // проснётся в фоне на ~30s, выполнит midnight-reset/sync и запишет свежий
        // `child_runtime_state.available_seconds`. В `focus_commands` запись не создаётся —
        // это не команда, а wake-сигнал, не должен проходить ACK-loop.
        return await wakeChildSync(authed.deviceId);
      default:
        return errorResponse("Unknown action", 400);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unexpected server error";
    return errorResponse(message, 500);
  }
});

async function queueBalanceCommand(deviceId: string, payload: Json): Promise<Response> {
  const commandType = asString(payload.commandType);
  const durationSeconds = asNumber(payload.durationSeconds);
  const intentID = asUUIDString(payload.intentID);

  // v4: добавлен subtract_earned_seconds. Расширяет add_earned_seconds зеркально (только положительное число секунд).
  if (
    commandType !== "reset_earned_balance" &&
    commandType !== "add_earned_seconds" &&
    commandType !== "subtract_earned_seconds"
  ) {
    return errorResponse("Invalid command type", 400);
  }
  if (
    (commandType === "add_earned_seconds" || commandType === "subtract_earned_seconds") &&
    !(durationSeconds && durationSeconds > 0)
  ) {
    return errorResponse(`durationSeconds must be > 0 for ${commandType}`, 400);
  }

  const parentDevice = await getDevice(deviceId);
  if (parentDevice.role !== "parent" || !parentDevice.family_id) return errorResponse("Parent device is not paired", 403);

  const { data: child, error: childError } = await supabase
    .from("devices")
    .select("id, apns_token")
    .eq("family_id", parentDevice.family_id)
    .eq("role", "child")
    .single();
  if (childError || !child) return errorResponse("Child device is not linked", 404);

  if (intentID) {
    const { data: existing, error: existingError } = await supabase
      .from("focus_commands")
      .select("id, family_id, command_type, duration_seconds, status, created_at, updated_at, retry_count, error_message, intent_id")
      .eq("requested_by_device_id", parentDevice.id)
      .eq("intent_id", intentID)
      .maybeSingle();
    if (existingError) return errorResponse(existingError.message, 400);
    if (existing) return okResponse(mapCommandForClient(existing as FocusCommandRow));
  }

  const hasToken = !!asString(child.apns_token);
  const nowIso = new Date().toISOString();
  const expiresAt = new Date(Date.now() + COMMAND_TTL_SECONDS * 1000).toISOString();
  const { data: command, error: commandError } = await supabase
    .from("focus_commands")
    .insert({
      family_id: parentDevice.family_id,
      requested_by_device_id: parentDevice.id,
      target_device_id: child.id,
      command_type: commandType,
      duration_seconds: durationSeconds,
      status: hasToken ? "sent" : "queued",
      error_message: hasToken ? null : "Child APNs token missing",
      retry_count: 0,
      last_push_attempt_at: hasToken ? nowIso : null,
      intent_id: intentID,
      expires_at: expiresAt,
    })
    .select("id, family_id, command_type, duration_seconds, status, created_at, updated_at, retry_count, error_message, intent_id")
    .single();
  if (commandError || !command) return errorResponse(commandError?.message ?? "Failed to queue command", 400);

  if (hasToken && child.apns_token) {
    await attemptPushForCommand(String(command.id), String(child.apns_token), commandType, durationSeconds, 0);
  }

  return okResponse(mapCommandForClient(command as FocusCommandRow));
}

async function updateChildBalance(deviceId: string, payload: Json): Promise<Response> {
  const childDevice = await getDevice(deviceId);
  if (childDevice.role !== "child" || !childDevice.family_id) return errorResponse("Only paired child can update balance", 403);

  const availableSeconds = Math.max(0, asNumber(payload.availableSeconds) ?? 0);
  const { error } = await supabase
    .from("child_runtime_state")
    .upsert({
      family_id: childDevice.family_id,
      child_device_id: childDevice.id,
      available_seconds: availableSeconds,
      updated_at: new Date().toISOString(),
    }, { onConflict: "family_id" });
  if (error) return errorResponse(error.message, 400);

  return okResponse({ ok: true });
}

async function fetchChildBalance(deviceId: string): Promise<Response> {
  const parentDevice = await getDevice(deviceId);
  if (parentDevice.role !== "parent" || !parentDevice.family_id) return errorResponse("Only paired parent can fetch balance", 403);

  const { data, error } = await supabase
    .from("child_runtime_state")
    .select("available_seconds")
    .eq("family_id", parentDevice.family_id)
    .maybeSingle();
  if (error) return errorResponse(error.message, 400);

  return okResponse({
    availableSeconds: Math.max(0, Number(data?.available_seconds ?? 0)),
  });
}

/// v5: Parent → backend → silent APNs background push на child.
/// Цель: «разбудить» child-приложение в фоне, чтобы оно выполнило
/// `resetDailyBalanceIfNeeded()` + `syncChildStatsSnapshotIfNeeded()`
/// и записало свежий `available_seconds` в `child_runtime_state`.
/// Это решает проблему «застывшего» баланса после полуночи, когда child app
/// долго не запускался — silent push даёт ~30s background time, чего достаточно
/// для одного синка. iOS троттлит такие push'и (~2–3/час на устройство),
/// поэтому клиент должен звать wake только при stale-данных (> 60s).
async function wakeChildSync(deviceId: string): Promise<Response> {
  const parent = await getDevice(deviceId);
  if (parent.role !== "parent" || !parent.family_id) {
    return errorResponse("Only paired parent can wake child", 403);
  }

  const { data: child, error: childError } = await supabase
    .from("devices")
    .select("id, apns_token")
    .eq("family_id", parent.family_id)
    .eq("role", "child")
    .maybeSingle();
  if (childError) return errorResponse(childError.message, 400);
  if (!child) return errorResponse("Child device is not linked", 404);

  const token = asString(child.apns_token);
  if (!token) {
    // У ребёнка ещё нет APNs token — возвращаем ok без push, чтобы parent UI
    // не падал в ошибку. После регистрации устройства token появится сам.
    return okResponse({ ok: true, sent: false, reason: "child_token_missing" });
  }

  try {
    await sendApnsBackground(token, "child_sync_request");
    return okResponse({ ok: true, sent: true });
  } catch (pushError) {
    const message = pushError instanceof Error ? pushError.message : "push send failed";
    return errorResponse(message, 502);
  }
}

async function attemptPushForCommand(
  commandID: string,
  token: string,
  commandType: string,
  durationSeconds: number | null,
  retryCount: number
): Promise<void> {
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
  }
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
    case "subtract_earned_seconds": {
      const seconds = durationSeconds ?? 0;
      const minutes = Math.max(1, Math.round(seconds / 60));
      return { title: "ParentalControl", body: `Родитель забрал ${minutes} мин времени` };
    }
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
  const payload: Record<string, unknown> = {
    aps: {
      alert: {
        title: localized.title,
        body: localized.body,
      },
      sound: "default",
      "mutable-content": 1,
      "content-available": 1,
      "interruption-level": "time-sensitive",
    },
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

/// Silent background push без alert: будит child-приложение в фоне для синка.
/// Используется только для `wake_child_sync`. Никаких `aps.alert`/`sound`/`mutable-content`,
/// иначе iOS прокинет push в banner. Только `content-available: 1` + custom keys.
async function sendApnsBackground(tokenRaw: string, commandType: string): Promise<void> {
  const auth = await apnsAuthHeaders();
  const token = tokenRaw.replace(/\s+/g, "");
  const payload: Record<string, unknown> = {
    aps: {
      "content-available": 1,
    },
    command_type: commandType,
  };
  // 5 минут TTL: silent push без срочности, iOS сам решит когда доставить.
  const expirationEpoch = Math.floor(Date.now() / 1000) + 300;
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
  const text = await res.text();
  if (!res.ok) throw new Error(`APNs background error ${res.status}: ${text}`);
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

async function getDevice(deviceId: string): Promise<{ id: string; role: string; family_id: string | null }> {
  const { data, error } = await supabase
    .from("devices")
    .select("id, role, family_id")
    .eq("id", deviceId)
    .single();
  if (error || !data) throw new Error(error?.message ?? "Device not found");
  return data as { id: string; role: string; family_id: string | null };
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

function okResponse(payload: unknown): Response {
  return new Response(JSON.stringify(payload), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

function errorResponse(message: string, status = 400): Response {
  return new Response(JSON.stringify({ error: message }), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}
