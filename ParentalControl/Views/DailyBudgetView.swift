import SwiftUI

struct DailyBudgetBalanceCard: View {
    let availableSeconds: Int
    let usedSeconds: Int
    let limitSeconds: Int?
    let earnedSeconds: Int?
    let grantedSeconds: Int?
    var isLoading = false
    var isLimitLoading = false
    var isManuallyBlocked = false
    var blockSchedules: [BlockSchedule] = []
    var isAwaitingConfirmation = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            balanceContent(isBlocked: isManuallyBlocked || blockSchedules.contains {
                $0.isActive(at: context.date)
            })
        }
    }

    private func balanceContent(isBlocked: Bool) -> some View {
        // Use the child's applied balance, not a newly saved limit still awaiting delivery.
        let budget = max(0, availableSeconds + usedSeconds)
        return VStack(spacing: 12) {
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
                            .opacity(isBlocked ? 0.2 : 1)
                    }.frame(width: 124, height: 124)
                        .overlay {
                            if isBlocked {
                                ZStack {
                                    Circle().fill(.black.opacity(0.25))
                                    VStack(spacing: 6) {
                                        Image(systemName: "lock.fill").accessibilityHidden(true)
                                        Text("budget.manual_block_active")
                                            .multilineTextAlignment(.center)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(10)
                                }
                                .allowsHitTesting(false)
                            }
                        }
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
            if isAwaitingConfirmation {
                Text("budget.pending")
                    .font(.caption)
                    .foregroundStyle(AppTheme.neonOrange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
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
    @State private var isWeekly: Bool
    @State private var weeklyMinutes: [Int]
    @State private var initializedWeeklyDraft: Bool
    @State private var editingDay: DayChoice?
    @State private var confirmsUniform = false
    private let originallyWeekly: Bool

    private struct DayChoice: Identifiable { let id: Int }

    init(policy: DailyBudgetPolicy?) {
        let total = max(0, min(1440, (policy?.limitSeconds ?? 0) / 60))
        let week = policy?.weeklyLimitsSeconds
        _hours = State(initialValue: total / 60)
        _minutes = State(initialValue: total % 60)
        _isWeekly = State(initialValue: week != nil)
        _initializedWeeklyDraft = State(initialValue: week != nil)
        _weeklyMinutes = State(initialValue: week?.map { $0 / 60 } ?? Array(repeating: total, count: 7))
        originallyWeekly = week != nil
    }

    private var canSave: Bool {
        appState.pairingState?.isLinked == true && appState.parentBudgetStatus?.childReady == true
            && (!isWeekly || appState.parentBudgetStatus?.weeklyChildReady == true)
            && !appState.isBudgetSaving
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("budget.explanation").fixedSize(horizontal: false, vertical: true)
                        Picker("budget.weekly.mode", selection: $isWeekly) {
                            Text("budget.every_day").tag(false)
                            Text("budget.weekly.by_days").tag(true)
                        }.pickerStyle(.segmented)
                        if isWeekly {
                            VStack(spacing: 0) {
                                ForEach(0..<7) { index in
                                    Button { editingDay = DayChoice(id: index) } label: {
                                        HStack(spacing: 12) {
                                            Text(DailyLimitWeekdays.names[index])
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text(L10n.f("unit.minutes.short", weeklyMinutes[index]))
                                            Image(systemName: "chevron.right").font(.caption)
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.vertical, 14)
                                        .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    if index < 6 { Divider() }
                                }
                            }
                            if appState.parentBudgetStatus?.weeklyChildReady != true {
                                Text("budget.weekly.update_child").foregroundStyle(AppTheme.neonOrange)
                            }
                        } else {
                            DailyLimitTimePicker(hours: $hours, minutes: $minutes)
                        }
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
                        Button {
                            if !isWeekly && (originallyWeekly || Set(weeklyMinutes).count > 1) {
                                confirmsUniform = true
                            } else { save() }
                        } label: {
                            HStack {
                                if appState.isBudgetSaving { ProgressView().tint(.white) }
                                Text("budget.save")
                            }
                        }
                        .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
                        .disabled(!canSave)
                    }
                    .padding()
                    .disabled(appState.isBudgetSaving)
                }.scrollIndicators(.hidden)
            }
            .navigationTitle(Text("budget.title"))
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: isWeekly) { _, enabled in
                if enabled && !initializedWeeklyDraft {
                    weeklyMinutes = Array(repeating: hours * 60 + minutes, count: 7)
                    initializedWeeklyDraft = true
                }
                appState.budgetError = nil
            }
            .confirmationDialog("budget.weekly.replace.title", isPresented: $confirmsUniform, titleVisibility: .visible) {
                Button("budget.weekly.replace.action") { save() }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("budget.weekly.replace.message")
            }
            .sheet(item: $editingDay) { day in
                DailyLimitDayEditor(day: day.id, minutes: weeklyMinutes[day.id]) { days, value in
                    for index in days { weeklyMinutes[index] = value }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(appState.isBudgetSaving)
    }

    private func save() {
        guard canSave else { return }
        let total = hours * 60 + minutes
        let week = isWeekly ? weeklyMinutes : nil
        Task {
            if await appState.saveParentDailyLimit(minutes: total, weeklyMinutes: week) { dismiss() }
        }
    }
}

private enum DailyLimitWeekdays {
    static let names: [String] = {
        let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? Locale.current.identifier)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.standaloneWeekdaySymbols
        return (0..<7).map { symbols[($0 + 1) % 7].capitalized(with: locale) }
    }()
}

private struct DailyLimitTimePicker: View {
    @Binding var hours: Int
    @Binding var minutes: Int

    var body: some View {
        HStack {
            Picker("budget.hours", selection: $hours) {
                ForEach(0...24, id: \.self) { Text("\($0) " + L10n.tr("budget.hours")).tag($0) }
            }
            Picker("budget.minutes", selection: $minutes) {
                ForEach(0...(hours == 24 ? 0 : 59), id: \.self) { Text("\($0) " + L10n.tr("budget.minutes")).tag($0) }
            }
        }
        .pickerStyle(.wheel)
        .onChange(of: hours) { _, value in if value == 24 { minutes = 0 } }
    }
}

private struct DailyLimitDayEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hours: Int
    @State private var minutes: Int
    @State private var selectedDays: Set<Int>
    let onApply: (Set<Int>, Int) -> Void

    init(day: Int, minutes: Int, onApply: @escaping (Set<Int>, Int) -> Void) {
        _hours = State(initialValue: minutes / 60)
        _minutes = State(initialValue: minutes % 60)
        _selectedDays = State(initialValue: [day])
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DailyLimitTimePicker(hours: $hours, minutes: $minutes)
                    Text("budget.weekly.apply_days").font(.headline)
                    ForEach(0..<7) { index in
                        Toggle(DailyLimitWeekdays.names[index], isOn: Binding(
                            get: { selectedDays.contains(index) },
                            set: { selected in
                                if selected { selectedDays.insert(index) }
                                else { selectedDays.remove(index) }
                            }))
                    }
                    Text("budget.weekly.draft_hint").font(.footnote).foregroundStyle(.secondary)
                    Button("budget.weekly.apply") {
                        onApply(selectedDays, hours * 60 + minutes)
                        dismiss()
                    }
                    .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
                    .disabled(selectedDays.isEmpty)
                }.padding()
            }
            .scrollIndicators(.hidden)
            .appScreenBackground()
            .navigationTitle(Text("budget.title"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }
}
