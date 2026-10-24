import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../../ParentalControl/Views/ChildTasksView.swift", import.meta.url), "utf8");
const state = readFileSync(new URL("../../ParentalControl/App/AppState.swift", import.meta.url), "utf8");

test("paused child tasks remain readable but do not offer report submission", () => {
  assert.match(source, /infoCard\(task\)\s+if task.status == \.pending \{\s+if appState.isFamilyAccessAllowed \{\s+sendReportButton\(task\)\s+\} else \{\s+Label\("tasks.child.access_paused"/);
  assert.match(source, /Text\(appState.isFamilyAccessAllowed \? "tasks.child.subtitle" : "tasks.child.access_paused"\)/);
});

test("report flow checks local access before camera, library, sharing and submission", () => {
  for (const name of ["openTaskCamera() async", "loadPhoto(_ item: PhotosPickerItem)", "handlePickedImage(_ image: UIImage)"]) {
    assert.ok(source.includes(`private func ${name} {\n        guard canContinueReport() else { return }`), name);
  }
  assert.match(source, /Button \{\s+guard canContinueReport\(\) else \{ return \}\s+showSourceDialog = true/);
  assert.match(source, /Button\("tasks.detail.report_source.library"\) \{\s+guard canContinueReport\(\) else \{ return \}/);
  assert.match(source, /guard canContinueReport\(\) else \{ return \}\s+if allowed \{ showCamera = true/);
  assert.match(source, /private func submit\(\) \{\s+guard !isSubmitting, canContinueReport\(\) else \{ return \}/);
  const gate = source.split("private func canContinueReport()")[1].split("private func dismissReportFlow()")[0];
  assert.match(gate, /guard FamilyAccessStore.allowed else/);
  assert.match(gate, /appState.adoptFamilyAccess\(\)\s+dismissReportFlow\(\)\s+return false/);
  assert.match(gate, /appState.deviceRole == \.child && task\?\.status == \.pending/);
  assert.ok(!/await|remoteSyncService|refreshFamilyAccess/.test(gate), "No extra access requests");
});

test("access ending mid-report dismisses sheets and avoids failed-mutation retry", () => {
  assert.match(source, /onChange\(of: appState.isFamilyAccessAllowed\) \{ _, allowed in\s+if !allowed \{ dismissReportFlow\(\) \}/);
  const dismiss = source.split("private func dismissReportFlow()")[1];
  for (const flag of ["showSourceDialog", "showCamera", "showLibrary", "isShareSheetPresented", "showMutationError", "showCameraPermissionAlert"]) {
    assert.ok(dismiss.includes(`${flag} = false`), flag);
  }
  const submit = source.split("private func submit()")[1].split("private func canContinueReport()")[0];
  assert.match(submit, /defer \{ isSubmitting = false \}/);
  assert.match(submit, /guard canContinueReport\(\) else \{ return \}\s+await appState.refreshChildTasksFromServer\(\)\s+guard canContinueReport\(\) else \{ return \}\s+showMutationError = true/);
  const mutation = state.split("private func changeChildTask(")[1];
  assert.ok(mutation.indexOf("guard requireFamilyAccess()") < mutation.indexOf("try await operation()"), "Existing model guard remains in force");
});
