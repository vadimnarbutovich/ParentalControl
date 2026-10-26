Recovery-only onboarding

Run: node Tests/RecoverySetup/validate.cjs
Also: node Tests/DeviceIdentity/validate.cjs

Executes the actual AppState preparation method with fake network/storage,
plus 256 combinations of permissions, role, PIN, budget and access state.
Network/protected-storage errors and a changed family must not produce a plan
that treats unknown settings as absent. Recovery never writes a PIN or budget.
Expired access skips paid budget polling and paid child app-selection setup.
Also checks pending parent-only families, server-side unlink, changed family,
offline retry and cancellation of a stale lookup. A nil preparation result
redirects navigation; unlike an empty step list, it cannot complete onboarding.
DeviceIdentity tests execute the Back action: credentials are retained, no
unlink is sent, and the authenticated recovery/reset flow (including child PIN)
is shown again. Existing localized Back/Next/pairing text is reused in all locales.

Hardware follow-up:
1. Keep the existing family and PIN; note the nondefault daily/weekly limits.
2. Reinstall the parent, choose Restore link. The existing install/share page
   appears first, with recovery-specific instructions and an Already installed
   button that continues without sharing or waiting for the child. Then only
   missing setup steps appear; no new PIN or limit is required. Verify the old PIN
   on the child. Also check the link and QR code when both apps were deleted.
3. Reinstall the child and restore. Regrant permissions/select apps if missing;
   verify the existing PIN before accessing the protected picker. Do not create
   a new PIN. Removal protection stays optional in Settings.
4. Close/relaunch during recovery: the short recovery flow must resume.
5. With no internet, recovery shows a retry, not editable default settings.
6. With expired paid/demo access, recovery still finishes without resetting the
   demo, granting paid access, or requiring a paid budget poll.
7. Fresh install/new-family setup and Settings onboarding replay stay complete.
8. Generate a parent's code without joining the child and reinstall: role
   selection appears, with no automatic deletion. Choosing either role discards
   only this pending family after server confirmation and starts fresh setup.
   Repeat with a persisted recovery marker from an older build: updating in
   place must escape the trap. Existing first-install setup is not reset.
9. Interrupt recovery with no network. Retry shows activity; Back returns to
   recovery lookup. Restore/reset becomes available again when network returns.
   Back itself never unlinks either phone or changes the subscription identity.
10. While the parent's role selection is open, join the child using the old code.
    Choosing a role must now show linked-family recovery without deleting it.
    Offline role selection must keep both the old code and local role unchanged.
