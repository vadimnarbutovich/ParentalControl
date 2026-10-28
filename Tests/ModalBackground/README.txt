Modal background visual regression preview

prepare-preview.cjs extracts the actual AdjustTimeSheet and ParentPinSetupSheet
bodies. It replaces only their app services with offline stubs; no credentials,
purchases or production requests are used. Generated files stay outside the repo.

From the repository root:

preview_dir=$(mktemp -d /private/tmp/parental-real-sheets.XXXXXX)
node Tests/ModalBackground/prepare-preview.cjs "$preview_dir"
xcrun swiftc -parse-as-library -target arm64-apple-ios18.0-simulator \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -module-cache-path "$preview_dir/cache" \
  ParentalControl/Design/AppTheme.swift \
  ParentalControl/Design/AppBackgroundView.swift \
  ParentalControl/Design/GlassCardStyle.swift \
  ParentalControl/Design/GlowModifiers.swift \
  ParentalControl/Localization/L10n.swift \
  "$preview_dir/Preview.swift" -o "$preview_dir/RealSheets.app/RealSheets"

Use an isolated booted simulator (replace SIMULATOR_UDID):
xcrun simctl install SIMULATOR_UDID "$preview_dir/RealSheets.app"
xcrun simctl launch SIMULATOR_UDID local.parental.realsheets -AppleLanguages '(ru)'

For PIN, terminate the preview and launch with the additional -pin argument.
Inspect the right/bottom edges, expanded sheet and PIN keyboard. In iOS 26 the
sheet is inset: its whole rounded rectangle must be painted with no straight
uncovered strips. Check iOS 18 as well. This is manual visual verification, not
an automated pixel assertion. The root behind the sheets is a simplified stub.

The global-canvas path on main screens must remain rasterized before clipping
to preserve the previously fixed iOS 18 pinned-banner seam. Local modal artwork
must fill the container directly, without that offscreen texture or crop.
