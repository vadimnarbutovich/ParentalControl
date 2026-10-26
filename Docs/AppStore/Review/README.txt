App Review purchase screenshot — 2026-10-25

Source: /Users/narbutovich/Downloads/paywall.png (591 x 1280 PNG).
Prepared: paywall-review-1125x2436.png (1125 x 2436, opaque sRGB PNG).
File size: 1710505 bytes.
MD5: 9a4b7b7f84c2d18d4978504fa397bbc1

The user approved deterministic scaling and alpha removal. No AI regeneration,
UI edits, text replacement, price changes, or cropping were performed.
prepare.swift uses aspect-fit scaling, high-quality interpolation and an opaque
RGB canvas. Scaling does not restore detail missing from the reduced source.

Intended destination: App Store Connect App Review screenshot, not public
marketing screenshots. The same real paywall shows all three purchase choices.
RevenueCat project: proj77ee7cb3 / ParentalControl.
Product IDs:
- Annual: prodff545d5d7b / mycompny.ParentalControl.pro.annual
- Monthly: prodef86c9af44 / mycompny.ParentalControl.pro.monthly
- Lifetime: prod2046b253a9 / mycompny.ParentalControl.pro.lifetime

Only review screenshot and review notes were sent in store-state patches.
Removed outdated notes claiming paid restrictions are disabled and the final
screenshot is still pending. No product or app was submitted for review.

Upload verification
- All three Apple uploads returned HTTP 200 with matching MD5/ETag.
- Annual screenshot: 0d7fd89c-95d2-45f3-8542-617e8e30a338
- Monthly screenshot: cca29712-b9a6-4332-a7ec-c4b1bfca017f
- Lifetime screenshot: 59c8147d-f0d5-4b07-9504-d1991a423f4e
- Annual/lifetime readback: matching screenshot checksum, READY_TO_SUBMIT.
- Monthly processing took longer. Direct Apple API readback confirmed COMPLETE,
  no errors/warnings, matching checksum and dimensions 1125 x 2436. A repeated
  commit during processing returned conflict; no second upload was necessary.
- Prices, territory availability and trial configuration were preserved.

Apple reference:
https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information/
https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/
