Reinstallation and device role — 2026-10-26

Behavior
- Keychain retains only install ID + secret. Legacy JSON containing a role
  remains readable, but the role is ignored and not written into new backups.
- A reinstall checks retained credentials once without creating/updating rows.
  No family: role selection. Existing family: Restore link / Set up again.
  Failed lookup: explicit Retry, never an implicit new family or background loop.
  An update preserves the existing App Group role, onboarding and pairing.
- Registration accepts a new role only for an authenticated, unpaired device.
  The conditional update changes only role, retaining device ID and access owner.
  A concurrent pairing/role change aborts rather than overwriting the new state.
- A still-paired device returns its authoritative server role. The new client
  restarts setup using that role; it cannot turn a linked child into a parent.
- Subscription verification, demo length, polling and purchase identity are
  unchanged. Same-role registration adds no database write or request.
- Reset requires confirmation; child reset also requires a freshly fetched
  parent PIN and family-scoped local authorization with the existing lockout.
  Missing/unavailable PIN cannot bypass this check; use the parent phone instead.
  Reset reuses unlink, scoped to the displayed family. A different current family
  is rejected. A retry after successful unlink is idempotent.
  Restore keeps onboarding incomplete to recheck permissions and app selection.
- Registration role support deployed in v24; recovery inspection and fenced
  unlink deployed in v25. Readback matched local sources. No schema or family
  data migration was performed. Other deployed dependencies are unchanged.

Checks
node Tests/DeviceIdentity/validate.cjs
  Compiles the actual credential-storage methods and Codable identity using
  an in-memory Keychain double; never reads/writes the developer's real Keychain.
  Also executes the actual recovery methods with in-memory network/storage
  adapters: single-flight, no polling retry, offline errors, restore, parent
  reset, child authorization and preserved credentials.
node --test Tests/DeviceIdentity/registration.test.cjs
  Executes the actual registration handler with a mock database.
node --experimental-strip-types --test Tests/SubscriptionAccess/*.test.ts
node Tests/SyncEfficiency/validate.cjs

Hardware acceptance
1. Unlink the test family before removing the old apps.
2. DELETE the apps (not an update/offload), then install the new TestFlight build.
3. Unlinked phones should show role selection. Select parent/child and finish setup.
4. Check pairing, 24-hour demo and commands. Server cleanup is not a normal
   installation requirement and should not be repeated to reset demo.
5. Installing an update over a configured app must keep its role and pairing.
6. Reinstall one phone WITHOUT unlinking: verify the recovery choice. Restore
   must retain the family, role and settings. Set up again must ask confirmation
   (and PIN on child), unlink successfully, then show role selection.
7. Cancel the confirmation/PIN: no unlink. Offline lookup/reset: show retry and
   keep the choice, not a success. Lost unlink response: retry must be safe.
8. A missing child PIN requires the parent phone, not an unprotected reset.
