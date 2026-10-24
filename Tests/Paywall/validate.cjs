// Static safety checks. Runtime StoreKit purchase testing still requires sandbox.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..');
const read = name => fs.readFileSync(path.join(root,name),'utf8');
const view = read('ParentalControl/Views/PaywallView.swift');
const header = view.split('private var header: some View')[1].split('private var features: some View')[0];
const closeBar = view.split('.safeAreaInset(edge: .top, spacing: 0)')[1].split('.safeAreaInset(edge: .bottom')[0];
assert.ok(!closeBar.includes('paywall.title.brand'), 'Only the close button remains pinned');
const title = view.split('private func scrollingTitle(following bounds: Anchor<CGRect>?) -> some View')[1].split('private func familyArtwork')[0];
assert.match(view, /\.overlayPreferenceValue\(PaywallIntroductionBoundsKey.self\) \{ bounds in\s+scrollingTitle\(following: bounds\)/);
assert.match(title, /\.offset\(y: geometry\[bounds\].minY - closeButtonSize - closeBarVerticalPadding\)/,
  'Title follows scrolling without moving the rest of the layout');
assert.match(title, /\.padding\(\.horizontal, closeButtonSize \+ 24\)/,
  'Leave room for the close button on either side of the centered title');
assert.match(title, /\.allowsHitTesting\(false\)/);
assert.match(title, /\.clipped\(\)/);
assert.match(header, /Text\("paywall.title.brand"\)[\s\S]*?\.hidden\(\)\s+\.accessibilityHidden\(true\)/,
  'Preserve original title space without showing or announcing a duplicate');
const features = view.split('private var features: some View')[1].split('private func feature(')[0];
const artwork = view.split('private func familyArtwork(endingAt bounds: Anchor<CGRect>?) -> some View')[1].split('private var header: some View')[0];
assert.match(view, /VStack\(spacing: 18\) \{\s+header\s+features\s+\}\s+\.anchorPreference\(key: PaywallIntroductionBoundsKey.self, value: \.bounds\)/,
  'Artwork bottom follows the introduction, not the plan cards');
assert.match(view, /\.backgroundPreferenceValue\(PaywallIntroductionBoundsKey.self\)[\s\S]*AppBackgroundView\(\)\s+familyArtwork\(endingAt: bounds\)/,
  'Artwork remains behind all text and controls');
assert.ok(!features.includes('onboardingFamily'), 'Artwork is no longer attached to the feature list');
assert.match(artwork, /Image\("onboardingFamily"\)/);
assert.match(artwork, /alignment: \.center/);
assert.match(artwork, /\.opacity\(0\.24\)/);
assert.match(artwork, /\.clipped\(\)/);
assert.match(artwork, /let topExtension = closeButtonSize \+ closeBarVerticalPadding/,
  'Extend only to the close button, not the physical top of the screen');
assert.match(artwork, /let height = introduction.height \+ topExtension/,
  'Artwork height depends on content size, never the scroll position');
assert.doesNotMatch(artwork, /maxY|geometry.size.height/,
  'Viewport position must not resize artwork during scrolling');
assert.match(artwork, /\.offset\(x: introduction.minX, y: introduction.minY - topExtension\)/,
  'Artwork moves intact with the introduction and stays above the plan cards');
assert.match(artwork, /min\(introduction.width, 360\)/, 'Keep the original modest width limit');
assert.match(artwork, /\.allowsHitTesting\(false\)/);
assert.match(artwork, /\.accessibilityHidden\(true\)/);
const footer = view.split('private var purchaseFooter: some View')[1].split('@ViewBuilder private var status: some View')[0];
assert.ok(header.indexOf('paywall.title.brand') < header.indexOf('access.statusKey'));
assert.ok(header.indexOf('access.statusKey') < header.indexOf('paywall.subtitle'));
assert.ok(!footer.includes('access.statusKey'), 'Current plan status must not be confused with the selected price');
const service = read('ParentalControl/Services/SubscriptionService.swift');
const config = read('ParentalControl/Services/RevenueCatConfig.swift');
const project = read('ParentalControl.xcodeproj/project.pbxproj');
assert.equal((project.match(/INFOPLIST_KEY_RevenueCatPublicSDKKey = appl_KrCdjMXWpMntCfiZHePfqlqHZyC;/g)||[]).length,2);
assert.ok(!project.includes('appl_VkzwWAHFBmJXNVJvjQIOgKcXvbM'));
assert.ok(!config.includes('proj35cefec3'));
assert.match(service,/let effective = FamilyAccessStore.allowed/);
assert.match(service,/checkTrialOrIntroDiscountEligibility\(product: product\)/);
assert.match(service,/annualTrialEligible = eligibility == \.eligible/);
assert.match(service,/annualTrialEligible = false/, 'Unknown eligibility must not promise a trial');
assert.match(view,/selectedPlan == \.annual && offersTrial/, 'Trial CTA only for eligible annual plan');
assert.match(view,/!access.hasPaidAccess && !access.awaitingConfirmation && subscriptionService.annualTrialEligible/);
assert.ok(view.includes('(hasTrial ? "paywall.cta.start_trial" : "paywall.cta.continue")'));
assert.match(view,/plan == \.annual && offersTrial\s*\? "paywall\.price\.annual_trial_format" : plan\.priceKey/, 'Ineligible users see regular billing price');
assert.match(read('ParentalControl/ru.lproj/Localizable.strings'), /"paywall\.cta\.start_trial" = "Попробовать бесплатно";/);
assert.match(read('ParentalControl/ru.lproj/Localizable.strings'), /"paywall\.cta\.continue" = "Продолжить";/);
assert.match(service,/package\.storeProduct\.productIdentifier == plan\.productIdentifier/);
assert.match(service,/if result\.userCancelled/);
assert.match(service,/guard hasActiveEntitlement else/);
assert.match(service,/hasActiveEntitlement && \(hasLifetimeAccess \|\| !FamilyAccessStore.allowed \|\| isAwaitingServerConfirmation\s+\|\| entitlementProductIdentifier == selectedPlan.productIdentifier\)/);
assert.match(service,/guard await confirmServerPurchase\(\) else/);
assert.match(service,/hasPaidAccess: effective && FamilyAccessStore.receipt\?\.lease.state == \.paid/);
assert.match(view,/switch access.action\(for: selectedPlan\)/);
assert.match(view,/access.currentPlan == plan/);
assert.ok(!view.includes('manageSubscriptionsSheet'), 'Paywall does not redirect purchases to subscription management');
assert.ok(!view.includes('selectCurrentPlanIfNeeded'), 'Do not change the user selection to the already owned plan');
assert.match(view, /selectedPlan: ProPurchasePlan = \.annual/);
assert.match(view, /await subscriptionService.refreshForPaywall\(\)/);
const refreshForPaywall = service.slice(service.indexOf('func refreshForPaywall()'), service.indexOf('func refreshCustomerInfo()'));
assert.match(refreshForPaywall, /await identityInitialization\?\.value/);
assert.match(refreshForPaywall, /!PurchaseCustomerIdentity.isCanonical\(Purchases.shared.appUserID\)/);
assert.match(refreshForPaywall, /identifyPurchaseOwner\(try await resolveServerPurchaseIdentity\(\)\)/);
assert.ok(!/restorePurchases|verifyServerPurchase|AppStore.sync/.test(refreshForPaywall), 'Opening paywall resolves identity, never restores or changes server access');
const identifyOwner = service.slice(service.indexOf('private func identifyPurchaseOwner'), service.indexOf('private func identifyStableUserIfNeeded'));
assert.match(identifyOwner, /Purchases.shared.logIn\(identity\)/);
assert.match(identifyOwner, /KeychainStore.save\(value: identity, key: key\)/);
assert.ok(!service.includes('SecItemDelete'), 'Identity update must not destroy the existing key on failure');
const appState = read('ParentalControl/App/AppState.swift');
const resolveOwner = appState.slice(appState.indexOf('service.resolveServerPurchaseIdentity ='), appState.indexOf('service.prepareServerPurchase ='));
assert.match(resolveOwner, /deviceRole == \.parent/);
assert.match(resolveOwner, /remoteSyncService.purchaseIdentity\(\)/);
assert.ok(!/accessStatus|verifyPurchase|restorePurchases/.test(resolveOwner), 'One owner lookup, no additional access polling');
assert.ok(!view.includes('Text("settings.premium.active")'), 'Lifetime is not a subscription');
assert.match(view,/localizedPriceString/);
assert.match(view,/paywall\.legal\.lifetime_disclaimer/);
for(const removed of ['selectedWeekly','startCloseCountdown','saveBadge','subscriptionService.isPro']){
  assert.ok(!view.includes(removed),'Removed: '+removed);
}
assert.ok(!/12\.99|1\.99|19\.99/.test(view),'No hardcoded storefront prices');
assert.match(view,/restorePurchases\(\)/);
assert.match(view,/privacyPolicyURL/);
assert.match(view,/termsOfUseURL/);
assert.ok(!view.includes('person.2.fill'), 'No space-consuming header illustration');
assert.match(view,/safeAreaInset\(edge: \.bottom/, 'Purchase action stays visible');
assert.match(view,/PaywallSavings\.annualPercent/);
assert.match(view,/PaywallSavings\.approximateBadgePercent\(annualSavings\)/);
for (const locale of fs.readdirSync(path.join(root, 'ParentalControl')).filter(name => name.endsWith('.lproj'))) {
  const strings = read(`ParentalControl/${locale}/Localizable.strings`);
  const badge = strings.match(/"paywall\.badge\.savings_format"\s*=\s*"([^"]+)"/);
  assert.ok(badge && badge[1].includes('≈%d%%'), `${locale}: approximation must be explicit`);
}
assert.match(view,/annualCurrency: annual\.currencyCode, monthlyCurrency: monthly\.currencyCode/);
assert.match(view,/if offersTrial \{\s+PaywallTrialBadge\(\)/);
assert.match(view,/ViewThatFits\(in: \.horizontal\)/, 'Long translations can stack');
assert.match(view,/@ScaledMetric/, 'Typography respects Dynamic Type');
assert.ok(!view.includes('SAVE 50%'), 'No fabricated discount');
console.log('PASS: paywall configuration and safety checks');
