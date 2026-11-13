Optional App Store update prompt

Run from repository root:
  xcrun swiftc ParentalControl/Models/AppUpdatePolicy.swift Tests/AppUpdate/main.swift -o /tmp/parental-update-tests
  /tmp/parental-update-tests
  node Tests/Localization/validate.cjs

Policy checks cover numeric version ordering, malformed values, app identity,
minimum iOS compatibility, daily cooldown, storefront conversion and empty results.

Manual integration checks on App Store, TestFlight or Debug builds:
- Use a build containing this update checker with a lower marketing version
  (CFBundleShortVersionString) than the published App Store version. Build numbers
  (CFBundleVersion) are not compared. All channels use the same eligibility rules.
- Open after onboarding with a newer compatible version available in the same storefront.
- Update opens the app's App Store page; Later leaves the app usable.
- Reopening within 24 hours does not repeat the prompt or lookup.
- Offline, current/newer installed version, unavailable storefront and incompatible
  update produce no alert and do not delay normal startup.
- Existing sheets/system alerts take priority. A valid StoreKit storefront is required.

AppUpdatePrompt has an Xcode preview for checking layout without changing versions
or contacting Apple. Actual older-to-newer App Store flow still requires a device check.
