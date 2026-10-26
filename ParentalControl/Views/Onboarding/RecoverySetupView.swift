import SwiftUI

/// Recovery is not first-time setup. Resolve the plan before showing editable
/// settings; retain the plan while advancing so permissions cannot shift pages.
struct RecoverySetupView: View {
    @EnvironmentObject private var appState: AppState
    @State private var steps: [OnboardingStep]?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        Group {
            if let steps, !steps.isEmpty {
                OnboardingFlowView(recoverySteps: steps)
            } else {
                VStack(spacing: 20) {
                    if failed {
                        Text("recovery.error").multilineTextAlignment(.center)
                        Button("setup.refresh") { Task { await prepare() } }
                            .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
                            .disabled(loading)
                    } else {
                        ProgressView()
                        Text("recovery.checking")
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await prepare() }
    }

    @MainActor private func prepare() async {
        guard !loading, steps == nil else { return }
        loading = true
        failed = false
        defer { loading = false }
        do {
            let plan = try await appState.prepareRecoveredSetup()
            guard !Task.isCancelled else { return }
            if plan.isEmpty { appState.completeOnboarding() }
            else { steps = plan }
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}
