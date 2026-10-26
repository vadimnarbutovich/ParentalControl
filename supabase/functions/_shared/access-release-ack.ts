// Additive recovery acknowledgement; ordinary command ACKs are unchanged.
export function permitsAccessReleaseAck(
  payload: Record<string, unknown>, commandType: string, access: Record<string, unknown>,
): boolean {
  return commandType === "tasks_updated" && payload.status === "applied" &&
    Number.isSafeInteger(payload.accessReleaseRevision) && Number(payload.accessReleaseRevision) > 0 &&
    access.enforced === true && access.state === "expired" &&
    access.revision === payload.accessReleaseRevision;
}
