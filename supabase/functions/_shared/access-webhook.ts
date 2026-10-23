// Webhooks are a refresh signal, never a source of entitlement truth.
// Do not log the authorization header, body, customer IDs or purchase details.
export async function authenticateWebhook(provided: string | null, expected: string): Promise<boolean> {
  if (!expected || expected.length < 32 || !provided || provided.length > 512) return false;
  const hash = async (value: string) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  const [a, b] = await Promise.all([hash(provided), hash(expected)]);
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return difference === 0;
}

type WebhookEvent = { id: string; customers: string[]; test: boolean;
  renewalExpiresAt?: number; sandbox?: boolean };
export function webhookEvent(body: unknown): WebhookEvent {
  const event = (body as { event?: Record<string, unknown> })?.event;
  if (!event || typeof event.id !== "string" || event.id.length < 1 || event.id.length > 128) throw new Error("Invalid event");
  if (event.type === "TEST") return { id: event.id, customers: [], test: true };
  if (event.app_id !== "app09b71b22ed") throw new Error("Unexpected application");
  const candidates = [event.app_user_id, event.original_app_user_id,
    ...(Array.isArray(event.aliases) ? event.aliases : []),
    ...(Array.isArray(event.transferred_from) ? event.transferred_from : []),
    ...(Array.isArray(event.transferred_to) ? event.transferred_to : [])];
  if (candidates.length > 100) throw new Error("Too many identities");
  const customers = [...new Set(candidates.filter((x): x is string =>
    typeof x === "string" && /^pc-[0-9a-f-]{36}$/i.test(x)))];
  const result: WebhookEvent = { id: event.id, customers, test: false };
  if (event.type === "RENEWAL" && typeof event.expiration_at_ms === "number" &&
      Number.isSafeInteger(event.expiration_at_ms) && event.expiration_at_ms > 0 &&
      ["SANDBOX", "PRODUCTION"].includes(String(event.environment))) {
    result.renewalExpiresAt = event.expiration_at_ms;
    result.sandbox = event.environment === "SANDBOX";
  }
  return result;
}

// The event is only a retry hint. It NEVER grants/extends access. An early
// renewal webhook may precede the API's new current billing period.
export function renewalNeedsRetry(event: WebhookEvent, owner: {
  sandbox_allowed: boolean; purchase_until: string | null; lifetime: boolean;
}, now = Date.now()): boolean {
  if (!event.renewalExpiresAt || event.renewalExpiresAt <= now ||
      event.sandbox !== owner.sandbox_allowed || owner.lifetime) return false;
  const end = Date.parse(owner.purchase_until ?? "");
  return !Number.isFinite(end) || end < event.renewalExpiresAt;
}
