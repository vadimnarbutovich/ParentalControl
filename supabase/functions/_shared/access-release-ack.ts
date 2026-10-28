// Additive recovery acknowledgement; ordinary command ACKs are unchanged.
export function permitsAccessReleaseAck(
  payload: Record<string, unknown>, commandType: string, access: Record<string, unknown>,
): boolean {
  return commandType === "tasks_updated" && payload.status === "applied" &&
    Number.isSafeInteger(payload.accessReleaseRevision) && Number(payload.accessReleaseRevision) > 0 &&
    // verification_required is also a server denial (e.g. expired demo with
    // no verified purchase), not a network error or a grant of paid access.
    access.enforced === true && ["expired", "verification_required"].includes(String(access.state)) &&
    access.controlUntilMs == null &&
    access.revision === payload.accessReleaseRevision;
}
