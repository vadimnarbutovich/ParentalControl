Unused resource/code cleanup — 2026-10-24

Removed:
- Eight image sets with no asset loading paths: ButtonGo, apps, focusSession,
  focusTime, health, notification, onboardingHero, timer.
- Unreachable exercise UI and conversion settings sheet, pose/camera capture
  pipeline, rep/step rewards, five exercise image sets and tests of that retired
  pipeline. The child photo-report camera uses a different implementation.
- Uncalled balance cards, confetti view, settings-row helper and write-only UI state.
- Unused Xcode Core Data template (PersistenceController and Item model).
- Template emoji widget and sample timer control, including their registrations.
- Disconnected Extensions/ copies. The actual root-level extension targets remain.

Keep intentionally:
- ConversionSettings decoder, historical ledger source values, stored exercise
  totals and historical statistics interpretation. Never delete persisted user data
  or enum cases solely because the original entry UI no longer exists.
- refreshStepsAndRewards: despite its old name, it performs the current daily reset.
- Legacy remote balance command handlers and task reward fallbacks. They are not
  equivalent to the retired local exercise reward pipeline.
- Live Activity and every real Screen Time / notification / location extension.
- Child task photo reports, camera permissions, parental PIN, subscriptions and
  all existing server/synchronization behavior.
- Localization strings, marketing originals, website files and build artifacts:
  these were not treated as unused runtime code or deleted wholesale.

Checks:
node Tests/Cleanup/validate.cjs
swift test
node Tests/Paywall/validate.cjs
node Tests/AccessBanner/validate.cjs
node Tests/Analytics/validate.cjs
node Tests/Localization/validate.cjs
node --experimental-strip-types --test Tests/SubscriptionAccess/*.test.ts Tests/LocationPush/*.test.ts
Run the Swift SubscriptionAccess and NotificationControl/Worker/Schedule suites
using the commands in their README files. Build the app and all extension targets.

LegacyCompatibilityTests covers old minute balances, repsPerMinute settings and
all historical ledger sources. Cleanup checks protect active assets/extensions,
camera reports and daily-reset code from accidental removal.

Validation completed:
- Debug and Release generic iOS builds succeeded (CODE_SIGNING_ALLOWED=NO).
- Release Assets.car contains only AppIcon and the four active image sets;
  no retired images or ParentalControl.momd remain in that Release bundle.
- All seven extension products remain embedded (six in PlugIns, usage report
  in the ExtensionKit Extensions directory).
- Swift package: 7 tests passed, including six historical-ledger source cases.
- Node subscription/location suites: 50 tests passed.
- Swift suites: 40 subscription, 69 notification-control, 11 worker,
  44 schedule, 42 PIN and 76 access-banner checks passed.
- Cleanup, paywall, banner, analytics and 21-locale checks passed.
- Existing ShieldAction switch/build-version warnings were not changed here.
This is not signed archive validation or a physical-device acceptance run.

Hardware smoke test after updating (no reinstall/re-pair required):
1. Existing pairing, balance, selected apps and PIN remain available.
2. Parent block/unblock, add time and schedules work with the child app closed.
3. Request location and submit a task photo report.
4. Open paywall/restore and check access after foreground/background transitions.

Recovery: deleted tracked files remain recoverable from Git. A temporary additional
backup was created outside the repository at
/private/tmp/parental-unused-backup.vneqXz
(source-before-cleanup.tar, images/, Extensions/, ParentalControl.xcdatamodeld/).
Temporary system storage is not a permanent archive.
