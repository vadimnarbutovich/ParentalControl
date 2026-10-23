import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = readFileSync(new URL("../../ParentalControl/App/AppState.swift", import.meta.url), "utf8");
const polling = source.slice(source.indexOf("private func startRemotePollingIfNeeded()"),
  source.indexOf("private func processPendingRemoteCommandsIfNeeded()"));
const focus = source.slice(source.indexOf("private func startFocusCountdownTask()"),
  source.indexOf("private func restoreFocusSessionIfNeeded()"));

test("linked-device polling refreshes access before ordinary synchronization", () => {
  const refresh = polling.indexOf("await self.refreshFamilyAccess()");
  const gate = polling.indexOf("guard FamilyAccessStore.allowed || FamilyAccessStore.isSettingUp else");
  assert.ok(refresh >= 0 && gate > refresh);
  assert.ok(gate < polling.indexOf("await self.pollChildAndApply("));
  assert.ok(gate < polling.indexOf("await self.refreshParentChildState()"));
  assert.match(polling.slice(gate), /guard FamilyAccessStore.allowed \|\| FamilyAccessStore.isSettingUp else \{\s*try\? await Task.sleep\(nanoseconds: Self.remotePollingIntervalNanos\)\s*continue\s*\}/);
  assert.match(polling, /await self.refreshFamilyAccess\(\)\s*guard !Task.isCancelled else \{ return \}\s*self.adoptFamilyAccess\(\)/);
});

test("focus countdown does not own access refresh or suspend its timer on expiry", () => {
  assert.ok(!focus.includes("refreshFamilyAccess()"));
  assert.ok(!focus.includes("guard FamilyAccessStore.allowed"));
  assert.ok(focus.includes("self.endFocusSession()"));
});

const read = (name: string) => readFileSync(new URL(`../../ParentalControl/${name}`, import.meta.url), "utf8");

test("child controls visibly pause without changing setup, parent paywalls or network gates", () => {
  const blocklist = read("Views/BlockListView.swift");
  assert.match(blocklist, /appState.deviceRole == \.child && !appState.isFamilyAccessAllowed/);
  assert.match(blocklist, /isChildControlPaused && !FamilyAccessStore.isSettingUp/);
  assert.match(blocklist, /\.disabled\(isChildSelectionPaused\)/);
  assert.match(blocklist, /if isChildSelectionPaused \{ pausedControlNotice \}/);
  assert.match(blocklist, /&& appState.isFamilyAccessAllowed && !appState.isLocalManualBlockSyncing/);
  assert.match(blocklist, /if isChildControlPaused \{\s*pausedControlNotice/);
  assert.match(blocklist, /Text\("access.paused"\)/);
  assert.match(blocklist, /guard appState.requireFamilyConfigurationAccess\(\) else \{ return \}/);
  const handler = source.split("func setLocalManualBlock(active: Bool)")[1].split("private func setLocalManualBlockLocked")[0];
  assert.match(handler, /if !FamilyAccessStore.allowed/);
  const slider = read("Design/ActionSlideButton.swift");
  assert.match(slider, /guard isEnabled else \{ return \}/);
  assert.match(slider, /guard isEnabled else \{ resetDrag\(\); return \}/);
  assert.match(slider, /\.disabled\(!isEnabled\)/);
});

test("renewal uses server check deadline and Premium uses effective paid access", () => {
  assert.match(source, /receipt\?\.needsRefresh\(uptime: ProcessInfo.processInfo.systemUptime\)/);
  const settings = read("Views/SettingsView.swift");
  const premium = settings.slice(settings.indexOf("private var premiumSection"), settings.indexOf("private var premiumSection") + 1100);
  assert.match(premium, /appState.isFamilyAccessAllowed && FamilyAccessStore.receipt\?\.lease.state == \.paid/);
  assert.ok(!premium.includes("hasActiveEntitlement"));
  assert.match(premium, /settings.premium.available/);
});

test("paid cached state has no local expiry monitor and foreground revalidates", () => {
  const enforcement = read("Services/FamilyAccessEnforcement.swift");
  assert.match(enforcement, /if receipt.lease.state == \.paid/);
  assert.ok(enforcement.indexOf("if receipt.lease.state == .paid") < enforcement.indexOf("let signature"));
  const active = source.split("func appDidBecomeActive()")[1].split("func appDidEnterBackground()")[0];
  assert.match(active, /await refreshFamilyAccess\(force: true\)/);
});

test("status changes notify child and expiration wake retries bypass only the retry gate", () => {
  const server = readFileSync(new URL("../../supabase/functions/parental-control-sync/index.ts", import.meta.url), "utf8");
  assert.ok(server.includes('action === "access_status" && result.accessChanged === true'));
  assert.ok(server.includes('&& command.command_type !== "tasks_updated"'));
  assert.ok(server.includes('if (!accessAllows(access, action, payload))'));
});

test("schedule editor dismisses only a successful save or delete and keeps its own paywall", () => {
  const editor = read("Views/ScheduleEditorView.swift");
  assert.match(editor, /let onSave: \(BlockSchedule\) -> Bool/);
  assert.match(editor, /if onSave\(updated\) \{ dismiss\(\) \}/);
  assert.match(editor, /if onDelete\?\(\) == true \{ dismiss\(\) \}/);
  assert.match(editor, /private func saveAndDismiss\(\) \{\s*guard appState.requireFamilyAccess\(\) else \{ return \}/);
  assert.match(editor, /\.familyAccessPaywall\(\)/);
  assert.match(source, /func commitBlockSchedule\(_ schedule: BlockSchedule\) -> Bool \{\s*guard requireFamilyAccess\(\) else \{ return false \}/);
});

test("expired dashboard actions remain tappable and do not claim active synchronization", () => {
  const dashboard = read("Views/MainTabView.swift");
  const enabled = dashboard.slice(dashboard.indexOf("private var isCommandButtonEnabled"), dashboard.indexOf("private var shouldShowDisabledVisualState"));
  assert.match(enabled, /if !appState.isFamilyAccessAllowed \{ return true \}/);
  assert.match(dashboard, /Button\("budget.adjust_today"\) \{\s*guard appState.requireFamilyAccess\(\) else \{ return \}/);
  assert.match(dashboard, /private var commandButtonTitleKey: LocalizedStringKey \{\s*if !appState.isFamilyAccessAllowed/);
  assert.match(dashboard, /isAwaitingConfirmation: appState.isFamilyAccessAllowed &&/);
  assert.match(dashboard, /isAccessPaused: !appState.isFamilyAccessAllowed/);
});

test("task and time drafts survive access denial including expiry while editor is open", () => {
  const tasks = read("Views/TasksTabView.swift");
  assert.match(tasks, /private func saveAndDismiss\(\) \{\s*guard appState.requireFamilyAccess\(\) else \{ return \}/);
  assert.match(tasks, /\.familyAccessPaywall\(\)/);
  const mutation = source.slice(source.indexOf("private func changeChildTask("));
  assert.ok(mutation.indexOf("guard requireFamilyAccess()") < mutation.indexOf("isUpdatingChildTasks = true"));
  const adjust = read("Views/MainTabView.swift").split("private struct AdjustTimeSheet: View")[1];
  assert.match(adjust, /let onApply: \(Int\) async -> Bool/);
  assert.match(adjust, /if succeeded \{ dismiss\(\) \}/);
  assert.match(adjust, /\.familyAccessPaywall\(\)/);
  assert.match(read("Views/DailyBudgetView.swift"), /\.familyAccessPaywall\(\)/);
});

test("only the foremost parent presentation handles a paywall request", () => {
  const host = read("Views/FamilyAccessPaywallPresenter.swift");
  assert.match(host, /guard appState.deviceRole == \.parent,\s*FamilyAccessPresentation.stack.presenter == id/);
  assert.match(host, /\.onDisappear \{ FamilyAccessPresentation.stack.unregister\(id\) \}/);
  assert.match(read("ContentView.swift"), /\.familyAccessPaywall\(isRoot: true\)/);
});
