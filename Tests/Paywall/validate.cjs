// Static safety checks. Runtime StoreKit purchase testing still requires sandbox.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..');
const read = name => fs.readFileSync(path.join(root,name),'utf8');
const view = read('ParentalControl/Views/PaywallView.swift');
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
assert.match(view,/selectedPlan == \.annual && subscriptionService\.annualTrialEligible/, 'Trial CTA only for eligible annual plan');
assert.ok(view.includes('(hasTrial ? "paywall.cta.start_trial" : "paywall.cta.continue")'));
assert.match(view,/plan == \.annual && subscriptionService\.annualTrialEligible\s*\? "paywall\.price\.annual_trial_format" : plan\.priceKey/, 'Ineligible users see regular billing price');
assert.match(read('ParentalControl/ru.lproj/Localizable.strings'), /"paywall\.cta\.start_trial" = "Попробовать бесплатно";/);
assert.match(read('ParentalControl/ru.lproj/Localizable.strings'), /"paywall\.cta\.continue" = "Продолжить";/);
assert.match(service,/package\.storeProduct\.productIdentifier == plan\.productIdentifier/);
assert.match(service,/if result\.userCancelled/);
assert.match(service,/guard hasActiveEntitlement else/);
assert.match(service,/hasActiveEntitlement && \(hasLifetimeAccess \|\| !FamilyAccessStore.allowed \|\| isAwaitingServerConfirmation\)/);
assert.match(service,/guard await confirmServerPurchase\(\) else/);
assert.match(view,/hasLifetimeAccess && subscriptionService.hasServerConfirmedPurchase/);
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
assert.match(view,/if subscriptionService\.annualTrialEligible \{\s+PaywallTrialBadge\(\)/);
assert.match(view,/ViewThatFits\(in: \.horizontal\)/, 'Long translations can stack');
assert.match(view,/@ScaledMetric/, 'Typography respects Dynamic Type');
assert.ok(!view.includes('SAVE 50%'), 'No fabricated discount');
console.log('PASS: paywall configuration and safety checks');
