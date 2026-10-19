import type { SupabaseClient } from "npm:@supabase/supabase-js@2.49.1";

type Environment = "sandbox" | "production";
const hosts: Record<Environment, string> = {
  sandbox: "api.sandbox.push.apple.com",
  production: "api.push.apple.com",
};

// All push paths (alerts, silent refresh, parent notifications, retries) use this
// transport. Credentials and payloads stay unchanged; only APNs routing changes.
export async function sendApnsToDevice(
  database: SupabaseClient,
  token: string,
  defaultHost: string,
  request: RequestInit,
  channel: "alert" | "location" = "alert",
): Promise<Response> {
  const tokenColumn = channel === "location" ? "location_push_token" : "apns_token";
  const environmentColumn = channel === "location" ? "location_push_environment" : "apns_environment";
  const { data, error } = await database.from("devices")
    .select("id, apns_environment, location_push_environment").eq(tokenColumn, token);
  if (error) throw new Error("Cannot resolve APNs environment");
  if (!data?.length) throw new Error("APNs token is no longer registered");
  const environments = new Set<Environment>();
  for (const device of data) {
    const value = device[environmentColumn];
    if (value === "sandbox" || value === "production") {
      environments.add(value);
    }
  }
  if (environments.size > 1) throw new Error("Conflicting APNs environments for token");
  const knownEnvironment = [...environments][0];
  let environment: Environment = knownEnvironment ??
    (defaultHost === hosts.production ? "production" : "sandbox");

  // No retry on network failures/timeouts or 200: APNs may already have accepted
  // the message. Only a definitive rejection for an UNKNOWN token allows one
  // attempt in the other environment (compatibility with already installed apps).
  let response = await fetch(`https://${hosts[environment]}/3/device/${token}`, request);
  if (!knownEnvironment && response.status === 400) {
    const rejection = await response.clone().json().catch(() => null);
    if (rejection?.reason === "BadDeviceToken") {
      environment = environment === "sandbox" ? "production" : "sandbox";
      response = await fetch(`https://${hosts[environment]}/3/device/${token}`, request);
    }
  }

  if (response.ok && !knownEnvironment) {
    // Compare-and-set protects a concurrent token change or explicit registration.
    // A persistence failure must NOT turn accepted delivery into a retry.
    try {
      const { error: saveError } = await database.from("devices")
        .update({ [environmentColumn]: environment })
        .in("id", data.map(device => device.id))
        .eq(tokenColumn, token).is(environmentColumn, null);
      if (saveError) console.warn("[APNs] accepted; environment persistence failed");
      else console.info(`[APNs] accepted; learned environment=${environment}`);
    } catch {
      console.warn("[APNs] accepted; environment persistence failed");
    }
  }
  if (!response.ok) {
    const rejection = await response.clone().json().catch(() => null);
    console.warn(`[APNs] rejected environment=${environment} status=${response.status} reason=${rejection?.reason ?? "unknown"}`);
  }
  return response;
}
