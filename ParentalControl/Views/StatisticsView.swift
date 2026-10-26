import DeviceActivity
import FamilyControls
import SwiftUI

/// Local-only report. Never exports Screen Time data or requests a server report.
struct StatisticsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var screenTimeService: ScreenTimeService
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var presentedSheet: StatisticsSheet?
    @State private var visible = false
    @State private var reportInterval: DateInterval?
    @State private var reportID = UUID()
    @State private var savedBudget: DailyBudgetState?
    @State private var loadingBudget = false

    private var canView: Bool { appState.deviceRole == .child && appState.isParentModeActive }
    private var calendar: Calendar { Calendar.current }
    private var selectedDay: String { DailyBudgetState.dayKey(selectedDate) }
    private var budget: DailyBudgetState? {
        if let current = appState.dailyBudget, current.day == selectedDay { return current }
        return savedBudget?.day == selectedDay ? savedBudget : nil
    }
    private var hasSelection: Bool {
        let selection = screenTimeService.selection
        return !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty || !selection.webDomainTokens.isEmpty
    }
    private var budgetRequestKey: String {
        "\(selectedDay):\(visible):\(canView):\(appState.pairingState?.familyID.uuidString ?? "unlinked"):\(appState.dailyBudget?.day ?? "")"
    }

    var body: some View {
        NavigationStack {
            Group {
                if canView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                            .fixedSize(horizontal: false, vertical: true)
                        dateSelector
                            .fixedSize(horizontal: false, vertical: true)
                        usageCard
                        summaryButton
                    }
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .appScreenBackground(usesSharedCanvas: true)
            .onAppear {
                visible = true
                screenTimeService.refreshAuthorizationStatus()
                refreshReport()
            }
            .onDisappear {
                visible = false
                presentedSheet = nil
                reportInterval = nil
            }
            .onChange(of: selectedDate) { _, _ in
                refreshReport()
                AppAnalytics.report("statistics_day_select")
            }
            .onChange(of: screenTimeService.selection) { _, _ in refreshReport() }
            .onChange(of: appState.dailyBudget?.day) { _, _ in refreshReport() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, visible, canView {
                    screenTimeService.refreshAuthorizationStatus()
                    refreshReport()
                }
            }
            .onChange(of: canView) { _, allowed in
                if !allowed { presentedSheet = nil; reportInterval = nil }
            }
            .task(id: budgetRequestKey) { await loadLocalBudget() }
            .sheet(item: $presentedSheet) { sheet in
                if canView {
                    switch sheet {
                    case .calendar:
                        StatisticsCalendarSheet(selectedDate: $selectedDate)
                    case .summary:
                        summarySheet
                    }
                }
            }
        }
    }

    private var header: some View {
        StatisticsDateHeader(title: "statistics.title", selectedDate: selectedDate) {
            presentedSheet = .calendar
            AppAnalytics.report("statistics_calendar_open")
        }
    }

    private var dateSelector: some View {
        StatisticsWeekStrip(selectedDate: $selectedDate, allowsFutureDates: false)
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("statistics.app_usage.title").font(.headline)
            if !screenTimeService.isAuthorized {
                Text("permission.banner.screentime.title").foregroundStyle(.secondary)
                Text("permission.banner.screentime.body").font(.subheadline).foregroundStyle(.secondary)
            } else if !hasSelection {
                Text("statistics.app_usage.empty_selection").font(.subheadline).foregroundStyle(.secondary)
            } else if selectedDate > calendar.startOfDay(for: Date()) {
                Text("statistics.app_usage.no_data").font(.subheadline).foregroundStyle(.secondary)
            } else if visible, let reportInterval {
                // Give the remote report an explicit viewport using the space left
                // below the title, within the navigation bar/tab bar safe area.
                GeometryReader { geometry in
                    DeviceActivityReport(
                        .init("parentalcontrol.daily-activity"),
                        filter: DeviceActivityFilter(
                            segment: .daily(during: reportInterval),
                            applications: screenTimeService.selection.applicationTokens,
                            categories: screenTimeService.selection.categoryTokens,
                            webDomains: screenTimeService.selection.webDomainTokens
                        )
                    )
                    .id(reportID)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    .background {
                        // No readiness callback is available to the host. The
                        // extension's opaque result covers this static hint.
                        Text("statistics.app_usage.loading_hint")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(20)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                            // It remains mounted behind the result; don't leave
                            // a stale loading announcement in VoiceOver's tree.
                            .accessibilityHidden(true)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .glassCard(cornerRadius: 24, glowColor: AppTheme.neonBlue, backgroundColor: AppTheme.usageReportBackground)
    }

    private var summaryButton: some View {
        Button {
            guard canView else { return }
            presentedSheet = .summary
            AppAnalytics.report("statistics_summary_open")
        } label: {
            Label("statistics.local.summary", systemImage: "chart.bar.xaxis")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
    }

    private var summarySheet: some View {
        NavigationStack {
            ScrollView {
                // Also gate the presented content if the role or PIN mode changes.
                if canView {
                    dayCard
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.hidden)
            .appScreenBackground()
            .navigationTitle(L10n.tr("statistics.local.summary"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var dayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(dateTitle(selectedDate)).font(.title3.bold())
            if let budget {
                row("budget.used", seconds: budget.usedSeconds)
                row("budget.title", seconds: budget.policy.limitSeconds)
                row("budget.earned", seconds: budget.earnedSeconds)
                row("budget.granted", seconds: budget.grantedSeconds)
            } else if loadingBudget {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text("reports.no_data").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassCard(cornerRadius: 24, glowColor: AppTheme.neonPurple)
    }

    private func row(_ key: String, seconds: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L10n.tr(key)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(seconds.map { $0 == 0 ? L10n.f("unit.minutes.short", 0) : L10n.duration(seconds: $0) } ?? "—")
                .fontWeight(.semibold).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }.font(.subheadline)
    }

    private func dateTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = statisticsLocale
        formatter.dateStyle = .long
        return formatter.string(from: date)
    }

    private func refreshReport() {
        guard visible, canView else { return }
        let start = calendar.startOfDay(for: selectedDate)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        // Snapshot only on entry or relevant changes, not every budget poll.
        let end = min(nextDay, Date())
        reportInterval = DateInterval(start: start, end: max(start, end))
        reportID = UUID()
    }

    @MainActor private func loadLocalBudget() async {
        savedBudget = nil
        guard visible, canView else { loadingBudget = false; return }
        loadingBudget = true
        let key = budgetRequestKey
        let date = selectedDate
        let familyID = appState.pairingState?.familyID.uuidString.lowercased()
        // Read just one archived day, off the UI thread. Do not advance/reset the budget.
        let saved = await Task.detached(priority: .userInitiated) {
            try? DailyBudgetStore.shared.history(for: date)
        }.value
        guard !Task.isCancelled, key == budgetRequestKey, canView else { return }
        savedBudget = saved?.policy.familyID.lowercased() == familyID ? saved : nil
        loadingBudget = false
    }
}

private enum StatisticsSheet: String, Identifiable {
    case calendar
    case summary

    var id: String { rawValue }
}

private struct StatisticsDateHeader: View {
    let title: LocalizedStringKey
    let selectedDate: Date
    let openCalendar: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text(L10n.f("statistics.selected.day", selectedDate.formatted(.dateTime.day().month(.wide).year())))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                openCalendar()
            } label: {
                Image(systemName: "calendar")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("statistics.calendar.title"))
            .glassCard(cornerRadius: 22, glowColor: AppTheme.neonBlue)
        }
    }
}

private struct StatisticsWeekStrip: View {
    @Binding var selectedDate: Date
    var allowsFutureDates = true
    var onSelectDay: (Date) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(weekDatesAroundSelectedDay(), id: \.self) { date in
                dayChip(for: date)
            }
        }
        .padding(10)
        .glassCard(cornerRadius: 22, glowColor: AppTheme.neonPurple)
    }

    private func dayChip(for date: Date) -> some View {
        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
        let isUnavailable = !allowsFutureDates && date > Calendar.current.startOfDay(for: Date())
        return Button {
            onSelectDay(date)
            selectedDate = date
        } label: {
            VStack(spacing: 5) {
                Text(shortWeekday(for: date))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.black.opacity(0.85) : .white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .allowsTightening(true)
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(isSelected ? Color.black.opacity(0.9) : .white)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? AppTheme.neonGreen : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .disabled(isUnavailable)
        .opacity(isUnavailable ? 0.3 : 1)
    }

    private func weekDatesAroundSelectedDay() -> [Date] {
        let calendar = Calendar.current
        let monday = startOfWeekMonday(for: selectedDate)
        return (0...6).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: monday)
        }
    }

    private func shortWeekday(for date: Date) -> String {
        return Self.weekdayFormatter.string(from: date).uppercased()
    }

    private func startOfWeekMonday(for date: Date) -> Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        components.weekday = 2
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = statisticsLocale
        formatter.setLocalizedDateFormatFromTemplate("EE")
        return formatter
    }()
}

private var statisticsLocale: Locale {
    Locale(identifier: Bundle.main.preferredLocalizations.first ?? Locale.current.identifier)
}

/// ScreenBlocker's month grid and expandable month/year wheels, with future days disabled.
private struct StatisticsCalendarSheet: View {
    @Binding var selectedDate: Date
    @Environment(\.dismiss) private var dismiss
    @State private var visibleMonthStart: Date
    @State private var pickerExpanded = false
    // Match the Monday–Sunday week strip, regardless of the device region.
    private let calendar: Calendar = {
        var value = Calendar.current
        value.firstWeekday = 2
        return value
    }()

    init(selectedDate: Binding<Date>) {
        _selectedDate = selectedDate
        _visibleMonthStart = State(initialValue: Calendar.current.dateInterval(of: .month, for: selectedDate.wrappedValue)?.start ?? selectedDate.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    HStack {
                        Button { shiftMonth(-1) } label: { monthArrow("chevron.left") }
                            .accessibilityLabel(Text("reports.previous"))
                        Spacer(minLength: 4)
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { pickerExpanded.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Text(monthTitle).font(.headline).multilineTextAlignment(.center)
                                Image(systemName: pickerExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption.bold()).foregroundStyle(AppTheme.neonGreen)
                            }
                        }
                        Spacer(minLength: 4)
                        Button { shiftMonth(1) } label: { monthArrow("chevron.right") }
                            .disabled(visibleMonthStart >= currentMonth)
                            .accessibilityLabel(Text("reports.next"))
                    }.buttonStyle(.plain)

                    if pickerExpanded {
                        HStack(spacing: 8) {
                            Picker("statistics.calendar.month", selection: monthBinding) {
                                ForEach(1...12, id: \.self) { month in
                                    Text(monthName(month)).tag(month)
                                }
                            }
                            Picker("statistics.calendar.year", selection: yearBinding) {
                                ForEach(years, id: \.self) { year in Text(String(year)).tag(year) }
                            }
                        }
                        .pickerStyle(.wheel).labelsHidden().frame(height: 160)
                    }

                    let days = monthGridDates()
                    let weekdays = weekdaySymbols()
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 8) {
                        // Indices also handle duplicate narrow weekday names and nil placeholders.
                        ForEach(weekdays.indices, id: \.self) { index in
                            Text(weekdays[index]).font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                                .allowsTightening(true)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(days.indices, id: \.self) { index in
                            if let date = days[index] { dayButton(date) }
                            else { Color.clear.frame(height: 38) }
                        }
                    }
                }.padding()
            }
            .scrollIndicators(.hidden)
            .appScreenBackground()
            .navigationTitle(L10n.tr("statistics.calendar.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("statistics.calendar.close") { dismiss() }
                        .tint(.white)
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var currentMonth: Date { calendar.dateInterval(of: .month, for: Date())?.start ?? Date() }
    private var years: ClosedRange<Int> {
        let current = calendar.component(.year, from: Date())
        let visible = calendar.component(.year, from: visibleMonthStart)
        return min(current - 5, visible)...current
    }
    private func monthArrow(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.headline.bold()).frame(width: 40, height: 40)
            .background(Color.white.opacity(0.12), in: Circle())
    }
    private func dayButton(_ date: Date) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: selectedDate)
        let future = date > calendar.startOfDay(for: Date())
        return Button {
            selectedDate = date
            dismiss()
        } label: {
            Text(String(calendar.component(.day, from: date)))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.black.opacity(0.88) : Color.white)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(selected ? AppTheme.neonGreen : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(future ? 0.3 : 1)
        }
        .buttonStyle(.plain).disabled(future)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func monthGridDates() -> [Date?] {
        let count = calendar.range(of: .day, in: .month, for: visibleMonthStart)?.count ?? 0
        let leading = (calendar.component(.weekday, from: visibleMonthStart) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + (0..<count).map {
            calendar.date(byAdding: .day, value: $0, to: visibleMonthStart)
        }
    }
    private func weekdaySymbols() -> [String] {
        let formatter = DateFormatter()
        formatter.locale = statisticsLocale
        let symbols = formatter.shortStandaloneWeekdaySymbols ?? formatter.shortWeekdaySymbols ?? []
        guard symbols.count == 7 else { return symbols }
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first]).map { $0.replacingOccurrences(of: ".", with: "").uppercased() }
    }
    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = statisticsLocale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("LLLL yyyy")
        return formatter.string(from: visibleMonthStart)
    }
    private func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = statisticsLocale
        formatter.calendar = calendar
        return formatter.standaloneMonthSymbols[month - 1]
    }
    private func shiftMonth(_ offset: Int) {
        if let date = calendar.date(byAdding: .month, value: offset, to: visibleMonthStart) {
            visibleMonthStart = min(date, currentMonth)
        }
    }
    private var monthBinding: Binding<Int> {
        Binding(get: { calendar.component(.month, from: visibleMonthStart) },
                set: { updateMonth($0, year: calendar.component(.year, from: visibleMonthStart)) })
    }
    private var yearBinding: Binding<Int> {
        Binding(get: { calendar.component(.year, from: visibleMonthStart) },
                set: { updateMonth(calendar.component(.month, from: visibleMonthStart), year: $0) })
    }
    private func updateMonth(_ month: Int, year: Int) {
        var components = calendar.dateComponents([.era, .year, .month], from: visibleMonthStart)
        components.year = year; components.month = month; components.day = 1
        if let date = calendar.date(from: components) { visibleMonthStart = min(date, currentMonth) }
    }
}
