import SwiftUI

struct DailyBudgetBalanceCard: View {
    let availableSeconds: Int
    let usedSeconds: Int
    let limitSeconds: Int?
    let earnedSeconds: Int?
    let grantedSeconds: Int?
    var isLoading = false
    var isLimitLoading = false

    var body: some View {
        // Use the child's applied balance, not a newly saved limit still awaiting delivery.
        let budget = max(0, availableSeconds + usedSeconds)
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .center, spacing: 12) {
                Text("budget.remaining.stacked")
                    .font(.headline).foregroundStyle(AppTheme.neonGreen)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text("budget.remaining"))
                MinutesRingView(progress: CGFloat(min(1, Double(max(0, availableSeconds)) / Double(max(1, budget)))), lineWidth: 16) {
                    VStack(spacing: 2) {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("\(availableSeconds < 60 ? max(0, availableSeconds) : availableSeconds / 60)")
                                .font(.system(size: 38, weight: .black, design: .rounded))
                                .minimumScaleFactor(0.6).lineLimit(1)
                            Text(L10n.tr(availableSeconds < 60 ? "unit.seconds.abbrev" : "unit.minutes.abbrev"))
                                .font(.subheadline.weight(.semibold))
                        }
                    }.foregroundStyle(.white)
                }.frame(width: 124, height: 124)
                    // The 16-point stroke extends 8 points beyond the ring's layout.
                    // Include its visible height when centering the title + ring group.
                    .padding(.vertical, 8)
            }.frame(width: 124)
            VStack(alignment: .leading, spacing: 3) {
                metric("budget.title", value: isLimitLoading ? nil : limitSeconds.map { L10n.duration(seconds: $0) } ?? L10n.tr("budget.not_set"))
                metric("budget.used", value: isLoading ? nil : L10n.duration(seconds: usedSeconds))
                metric("budget.earned", value: earnedSeconds.map { L10n.duration(seconds: $0) })
                metric("budget.granted", value: grantedSeconds.map { L10n.duration(seconds: $0) })
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Color.clear.glassCard(cornerRadius: 28, glowColor: AppTheme.neonBlue)
            .padding(36).drawingGroup().padding(-36))
    }

    private func metric(_ key: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.tr(key)).font(.caption).foregroundStyle(.secondary)
            if let value {
                Text(value).font(.headline).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small).tint(.white)
            }
        }
    }
}

struct DailyLimitSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var hours: Int
    @State private var minutes: Int

    init(seconds: Int?) {
        let total = max(0, min(1440, (seconds ?? 0) / 60))
        _hours = State(initialValue: total / 60)
        _minutes = State(initialValue: total % 60)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("budget.explanation").fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Picker("budget.hours", selection: $hours) {
                                ForEach(0...24, id: \.self) { Text("\($0) " + L10n.tr("budget.hours")).tag($0) }
                            }
                            Picker("budget.minutes", selection: $minutes) {
                                ForEach(0...(hours == 24 ? 0 : 59), id: \.self) { Text("\($0) " + L10n.tr("budget.minutes")).tag($0) }
                            }
                        }.pickerStyle(.wheel)
                        Text("budget.rules").font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if appState.parentBudgetStatus?.policy == nil {
                            Text("budget.first_activation").font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if appState.parentBudgetStatus?.childReady != true {
                            Text("budget.child_update").foregroundStyle(AppTheme.neonOrange)
                        }
                        if let error = appState.budgetError {
                            Text(error).foregroundStyle(AppTheme.neonOrange).fixedSize(horizontal: false, vertical: true)
                        }
                        Button("budget.save") {
                            Task {
                                if await appState.saveParentDailyLimit(minutes: hours * 60 + minutes) { dismiss() }
                            }
                        }
                        .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
                        .disabled(appState.isBudgetSaving || appState.parentBudgetStatus?.childReady != true)
                    }.padding()
                }.scrollIndicators(.hidden)
            }
            .navigationTitle(Text("budget.title"))
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: hours) { _, value in if value == 24 { minutes = 0 } }
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(appState.isBudgetSaving)
    }
}
