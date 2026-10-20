Notification control pilot — 2026-10-20

Scope
Manual indefinite block/unblock and revisioned daily-budget updates through visible
APNs notifications. Location Push, scheduled shields, parent notifications and legacy
additive commands are not rerouted. No server deployment or database migration needed.
Delivery, actual ManagedSettings enforcement and DeviceActivity restart MUST be
verified on hardware; a successful build or HTTP ACK does not establish that.

Local tests (from project root)
xcrun swiftc ParentalControl/Models/DailyBudget.swift ParentalControl/Models/ParentFocusConfirmation.swift ParentalControl/Services/RemoteControlGate.swift NotificationServiceExtension/NotificationControlSnapshot.swift NotificationServiceExtension/NotificationDeliveryLifetime.swift Tests/NotificationControl/main.swift -o /tmp/parental-notification-control-tests
/tmp/parental-notification-control-tests

Before TestFlight
The NotificationServiceExtension App ID is:
mycompny.ParentalControl.NotificationServiceExtension
It now needs the Family Controls entitlement, including Apple's distribution
approval and a refreshed provisioning profile for this specific App ID.
Do not remove the entitlement just to make an archive export pass.
The host's existing entitlement does not grant it to the notification extension.
Local profile check on 2026-10-20 (rechecked after hardening):
Development profile created 2026-10-20 includes Family Controls and App Group.
Cached App Store profile created 2026-10-09 includes App Group but NOT Family Controls.
Both are unexpired. Portal approval was not checked; a cached profile missing the
entitlement does not establish whether distribution access has been approved.
Refresh the distribution profile if already approved, otherwise request approval:
https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement
Before export, also align extension CFBundleVersion with the host: the unsigned
build currently warns about extension build 1 versus host build 3.

Hardware acceptance (both supported test iPhones, without Xcode debugger)
1. Update both devices, open the child app once. Verify pairing, Screen Time
   authorization, selected test apps and an initialized daily allowance.
2. Allow visible notifications on child. For locked-screen tests enable previews.
   Do not hide the app. Record Low Power Mode and Background App Refresh settings.
3. Leave ParentalControl for another app. From parent: block -> unblock -> add 5 min.
   Check actual shield on selected app, not just parent UI/notification.
4. Exhaust the allowance, add 5 min, USE the selected app for 60+ seconds.
   Verify consumption continues and allowance eventually blocks again.
5. Manual unblock with zero balance must NOT unlock apps. Unblocking or adding
   minutes during an active bedtime schedule must NOT clear its named shield.
6. Repeat after 15–30 minutes with locked screen; repeat offline then reconnect.
7. Rapid block/unblock and repeated notification delivery: latest revision wins,
   minutes added once. Open child app afterwards: no reverted shield or stale UI.
8. PIN-mode local action plus remote action; unlink; revoke Screen Time access.
   No action for wrong family or stale command, no false successful ACK on errors.
9. Disable notifications: existing host/poll fallback is best-effort, NOT a
   guarantee of immediate background execution.

Diagnostics
Console.app: process NotificationServiceExtension, subsystem
mycompny.ParentalControl, category NotificationControl.
Stages: received -> locally_applied -> acknowledged; unfinished on failure.
Deadline / system_expiry is logged by the independent delivery callback, without
waiting for MainActor or App Group I/O. On expiry the last persisted stage may
therefore remain system_monitoring_check (the system API call is still blocked).
On server, requests should now also have NotificationServiceExtension in User-Agent.
Capture timestamp + command UUID and correlate focus_commands/runtime revisions.
No device credentials, task content or coordinates are logged by the pilot.
The latest stage/failure is also saved in App Group preferences under
parentalcontrol.notificationControlDiagnostic. It contains only timestamp,
command ID/type, stage, a fixed reason string and numeric error code.
Authorization diagnostics preserve the actual AuthorizationStatus raw value.
On the test device NSE reports notDetermined (0) while the host is authorized.
The pilot no longer treats that alone as denial. Explicit denial still stops
processing; every command must successfully register the real daily budget
monitor using DeviceActivity before changing budget/focus state. A system
unauthorized/monitoring error prevents acknowledgement. No cached consent or
permission prompts are used in NSE. Validate this path and revocation on hardware.
Do not sign off the experiment if ManagedSettings setters return but apps remain
unblocked, usage monitoring does not run, or the extension hits its memory limit.
In these cases collect extension crash/system logs and keep the host fallback.

Limitations
NSE has limited execution time and memory and depends on visible notification
delivery/settings. The processor makes bounded calls and returns the original
notification on timeout. It does not request location or fabricate background
location activity to execute unrelated commands.
The content handler and cancellation flag now run independently of MainActor.
This cannot interrupt an in-flight synchronous system API call or undo its side
effects; once it returns, cancellation checks prevent subsequent work / ACK.
The process lease remains held until that call unwinds, preserving serialization.
Tests cover exactly-once delivery, late worker completion, cancellation, blocked
main-thread expiry and stale / non-focus parent snapshot confirmation.
Validation after hardening: 52 local checks, Debug and Release iphoneos builds
(CODE_SIGNING_ALLOWED=NO), and syntax validation of all 21 localization files.
This is not a signed distribution/archive validation or a hardware acceptance run.
The parent keeps last confirmed runtime during delivery and offline/error states,
never projecting desired into applied. Waiting/result messages are visible in
release UI. A matching snapshot older than the command cannot confirm it, and a
focus snapshot cannot confirm a budget/task command. Retry policy is unchanged.
