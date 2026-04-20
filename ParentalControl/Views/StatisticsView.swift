import FamilyControls
import SwiftUI
#if canImport(DeviceActivity)
import DeviceActivity
#endif

private enum StatisticsSegment: String, CaseIterable, Identifiable {
    case activity
    case appUsage

    var id: String { rawValue }
}

private enum StatisticsCardIcon {
    case system(String)
    case asset(String)
}

private enum StatisticsLayout {
    /// Горизонтальный внутренний отступ карточки метрик.
    static let cardHorizontalPadding: CGFloat = 16
    /// Вертикальный отступ сверху и снизу (одинаковый: от края стекла до текста и от текста до края).
    static let cardVerticalPadding: CGFloat = 24
    /// Минимальный зазор иконки от верхнего и правого края контента карточки.
    static let iconEdgeInset: CGFloat = 3
    /// Резерв справа под иконку (ширина колонки иконки ~56 + inset 3 с края; меньше значение — текст ближе к иконке).
    static let textTrailingReserve: CGFloat = 44
}

struct StatisticsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var segment: StatisticsSegment = .activity
    @State private var dailyStats = DailyStats(
        date: Date(),
        steps: 0,
        earnedSeconds: 0,
        spentSeconds: 0,
        pushUps: 0,
        squats: 0,
        focusSessionTotalSeconds: 0
    )
    @State private var isLoading = false
    @State private var isCalendarSheetPresented = false
    @State private var statsByDayCache: [Date: DailyStats] = [:]
    @State private var statsLoadTask: Task<Void, Never>?
    @State private var hasOpenedAppUsage = false
    @State private var appUsageDisplayDate: Date = Date()
    @State private var appUsageIntervalsByDay: [Date: DateInterval] = [:]

    private var normalizedSelectedDate: Date {
        Calendar.current.startOfDay(for: selectedDate)
    }

    private func analyticsDayKey(for date: Date) -> String {
        let cal = Calendar.current
        let d = cal.startOfDay(for: date)
        let c = cal.dateComponents([.year, .month, .day], from: d)
        guard let y = c.year, let m = c.month, let day = c.day else { return "" }
        return String(format: "%04d-%02d-%02d", y, m, day)
    }

    /// Разбивка по приложениям через `DeviceActivityReport` + report extension в текущей сборке доступна с iOS 26.
    private var supportsDeviceActivityAppUsageUI: Bool {
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerSection
                        weekStripSection
                        if supportsDeviceActivityAppUsageUI {
                            segmentSection
                        }
                        contentSection
                    }
                    .padding()
                }
                .scrollIndicators(.hidden)
            }
            .task {
                if supportsDeviceActivityAppUsageUI {
                    appUsageDisplayDate = normalizedSelectedDate
                }
            }
            .onAppear {
                resetStatisticsEntryState()
            }
            .onChange(of: selectedDate) { _, newDate in
                scheduleStatsLoad(for: newDate)
                guard supportsDeviceActivityAppUsageUI, segment == .appUsage else { return }
                appUsageDisplayDate = Calendar.current.startOfDay(for: newDate)
                ensureAppUsageInterval(for: appUsageDisplayDate)
            }
            .onChange(of: appState.balance.totalSpentSeconds) { _, _ in
                refreshVisibleDayIfNeeded()
            }
            .onChange(of: appState.ledger.count) { _, _ in
                refreshVisibleDayIfNeeded()
            }
            .onChange(of: appState.todaySteps) { _, _ in
                refreshVisibleDayIfNeeded()
            }
            .onChange(of: segment) { _, newSegment in
                guard supportsDeviceActivityAppUsageUI, newSegment == .appUsage else { return }
                hasOpenedAppUsage = true
                appUsageDisplayDate = normalizedSelectedDate
                ensureAppUsageInterval(for: appUsageDisplayDate)
            }
            .sheet(isPresented: $isCalendarSheetPresented) {
                StatisticsCalendarSheet(selectedDate: $selectedDate)
            }
        }
    }

    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("statistics.title")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text(L10n.f("statistics.selected.day", dayTitle(for: selectedDate)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                AppAnalytics.report("statistics_calendar_open")
                isCalendarSheetPresented = true
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
            .glassCard(cornerRadius: 22, glowColor: AppTheme.neonBlue)
        }
    }

    private var weekStripSection: some View {
        HStack(spacing: 8) {
            ForEach(weekDatesAroundSelectedDay(), id: \.self) { date in
                dayChip(for: date)
            }
        }
        .padding(10)
        .glassCard(cornerRadius: 22, glowColor: AppTheme.neonPurple)
    }

    private var segmentSection: some View {
        HStack(spacing: 8) {
            ForEach(StatisticsSegment.allCases) { item in
                Button {
                    let seg = item == .activity ? "activity" : "app_usage"
                    AppAnalytics.report("statistics_segment_tap", parameters: ["segment": seg])
                    withAnimation(.easeInOut(duration: 0.18)) {
                        segment = item
                    }
                } label: {
                    Text(item == .activity ? "statistics.segment.activity" : "statistics.segment.app_usage")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    NeonChipButtonStyle(
                        isActive: segment == item,
                        tint: item == .activity ? AppTheme.neonGreen : AppTheme.neonBlue
                    )
                )
            }
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        if supportsDeviceActivityAppUsageUI {
            ZStack {
                activityGrid
                    .opacity(segment == .activity ? 1 : 0)
                    .allowsHitTesting(segment == .activity)

                if hasOpenedAppUsage || segment == .appUsage {
                    appUsageContainer
                        .opacity(segment == .appUsage ? 1 : 0)
                        .allowsHitTesting(segment == .appUsage)
                }
            }
        } else {
            activityGrid
        }
    }

    private var activityGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            spacing: 12
        ) {
            statisticsCard(
                title: L10n.tr("statistics.earned"),
                value: L10n.duration(seconds: dailyStats.earnedSeconds),
                icon: .system("arrow.up.right"),
                glow: AppTheme.neonGreen
            )
            statisticsCard(
                title: L10n.tr("statistics.spent"),
                value: L10n.duration(seconds: dailyStats.spentSeconds),
                icon: .system("arrow.down.right"),
                glow: AppTheme.neonOrange
            )
            statisticsCard(
                title: L10n.tr("statistics.steps"),
                value: formattedNumber(dailyStats.steps),
                icon: .asset("walk"),
                glow: AppTheme.neonBlue
            )
            statisticsCard(
                title: L10n.tr("statistics.squats"),
                value: formattedNumber(dailyStats.squats),
                icon: .asset("squat"),
                glow: AppTheme.neonPurple
            )
            statisticsCard(
                title: L10n.tr("statistics.pushups"),
                value: formattedNumber(dailyStats.pushUps),
                icon: .asset("pushups"),
                glow: AppTheme.neonBlue
            )
            statisticsCard(
                title: L10n.tr("statistics.focus.total"),
                value: L10n.duration(seconds: dailyStats.focusSessionTotalSeconds),
                icon: .system("timer"),
                glow: AppTheme.neonGreen
            )
        }
        .overlay {
            if isLoading {
                ProgressView()
                    .tint(.white)
                    .padding()
                    .glassCard(cornerRadius: 14)
            }
        }
    }

    private var appUsageContainer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("statistics.app_usage.title", systemImage: "hourglass.badge.plus")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))

#if canImport(DeviceActivity)
            if #available(iOS 26.0, *) {
                if let interval = appUsageIntervalsByDay[Calendar.current.startOfDay(for: appUsageDisplayDate)] {
                    DailyAppUsageReportCard(
                        reportInterval: interval,
                        selection: appState.screenTimeService.selection
                    )
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .onAppear {
                            ensureAppUsageInterval(for: appUsageDisplayDate)
                        }
                }
            } else {
                Text("statistics.app_usage.unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
#else
            Text("statistics.app_usage.unavailable")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
#endif
        }
        .padding()
        .glassCard(cornerRadius: 24, glowColor: AppTheme.neonBlue)
    }

    private func statisticsCard(title: String, value: String, icon: StatisticsCardIcon, glow: Color) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.32)
                    .allowsTightening(true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(value)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.1)
                    .allowsTightening(true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.trailing, StatisticsLayout.textTrailingReserve)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, StatisticsLayout.cardHorizontalPadding)
        .padding(.vertical, StatisticsLayout.cardVerticalPadding)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            statisticsCardIconView(icon: icon, glow: glow)
                .padding(.top, StatisticsLayout.iconEdgeInset)
                .padding(.trailing, StatisticsLayout.iconEdgeInset)
        }
        .glassCard(cornerRadius: 20, glowColor: glow)
        .padding(36)
        .drawingGroup()
        .padding(-36)
    }

    @ViewBuilder
    private func statisticsCardIconView(icon: StatisticsCardIcon, glow: Color) -> some View {
        switch icon {
        case .system(let name):
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [glow.opacity(0.22), glow.opacity(0.05), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 28
                        )
                    )
                    .frame(width: 58, height: 58)
                    .blur(radius: 3)
                Image(systemName: name)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(glow)
                    .shadow(color: glow.opacity(0.35), radius: 6, x: 0, y: 0)
            }
            .frame(width: 56, height: 56)
        case .asset(let name):
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [glow.opacity(0.24), glow.opacity(0.06), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 30
                        )
                    )
                    .frame(width: 62, height: 62)
                    .blur(radius: 3)
                Image(name)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .shadow(color: glow.opacity(0.28), radius: 8, x: 0, y: 0)
            }
            .frame(width: 56, height: 56)
        }
    }

    private func dayChip(for date: Date) -> some View {
        let isSelected = Calendar.current.isDate(date, inSameDayAs: normalizedSelectedDate)
        return Button {
            AppAnalytics.report(
                "statistics_day_chip_tap",
                parameters: ["date_key": analyticsDayKey(for: date)]
            )
            selectedDate = date
        } label: {
            VStack(spacing: 5) {
                Text(shortWeekday(for: date))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.black.opacity(0.85) : .white.opacity(0.72))
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
    }

    private func weekDatesAroundSelectedDay() -> [Date] {
        let calendar = Calendar.current
        let monday = startOfWeekMonday(for: normalizedSelectedDate)
        return (0...6).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: monday)
        }
    }

    private func loadStats(for date: Date) async {
        let normalizedDate = Calendar.current.startOfDay(for: date)
        if let cached = statsByDayCache[normalizedDate] {
            dailyStats = cached
            return
        }
        isLoading = true
        let stats = await appState.dailyStats(for: normalizedDate)
        statsByDayCache[normalizedDate] = stats
        dailyStats = stats
        isLoading = false
    }

    private func refreshVisibleDayIfNeeded() {
        let calendar = Calendar.current
        if supportsDeviceActivityAppUsageUI, segment != .activity { return }
        guard calendar.isDateInToday(selectedDate) else { return }
        let stats = appState.dailyStats(for: selectedDate, steps: appState.todaySteps)
        let normalizedDate = calendar.startOfDay(for: selectedDate)
        statsByDayCache[normalizedDate] = stats
        dailyStats = stats
    }

    private func dayTitle(for date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year())
    }

    private func shortWeekday(for date: Date) -> String {
        Self.weekdayFormatter.string(from: date).uppercased()
    }

    private func startOfWeekMonday(for date: Date) -> Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        components.weekday = 2
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private func formattedNumber(_ value: Int) -> String {
        Self.decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func scheduleStatsLoad(for date: Date, debounce: Bool = true) {
        statsLoadTask?.cancel()
        let targetDate = date
        statsLoadTask = Task {
            if debounce {
                // Debounce rapid swipes to prevent multiple heavy HealthKit requests.
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
            }
            await loadStats(for: targetDate)
        }
    }

    private func ensureAppUsageInterval(for date: Date) {
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: date)
        let isToday = calendar.isDateInToday(normalizedDate)
        if appUsageIntervalsByDay[normalizedDate] != nil && !isToday {
            return
        }

        let start = normalizedDate
        let nextDay = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        // Snapshot once per day to avoid continuous report recalculation on "today".
        let end = min(nextDay, Date())
        appUsageIntervalsByDay[normalizedDate] = DateInterval(start: start, end: end > start ? end : nextDay)
    }

    private func resetStatisticsEntryState() {
        let today = Calendar.current.startOfDay(for: Date())
        segment = .activity
        if supportsDeviceActivityAppUsageUI {
            appUsageDisplayDate = today
            if hasOpenedAppUsage {
                ensureAppUsageInterval(for: today)
            }
        }
        // Show cached data immediately to avoid blank screen
        if let cached = statsByDayCache[today] {
            dailyStats = cached
        }
        if selectedDate == today {
            // Same day — onChange won't fire, load directly without debounce
            scheduleStatsLoad(for: today, debounce: false)
        } else {
            // Different day — setting selectedDate triggers onChange,
            // which will handle loading with debounce.
            // Cached data (if any) is already shown above.
            selectedDate = today
        }
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EE")
        return formatter
    }()
}

private struct StatisticsCalendarSheet: View {
    @Binding var selectedDate: Date
    @Environment(\.dismiss) private var dismiss
    @State private var visibleMonthStart: Date
    @State private var isMonthYearPickerExpanded = false

    private let calendar = Calendar.current

    init(selectedDate: Binding<Date>) {
        _selectedDate = selectedDate
        let monthStart = Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: selectedDate.wrappedValue)
        ) ?? Date()
        _visibleMonthStart = State(initialValue: monthStart)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    Button {
                        shiftMonth(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isMonthYearPickerExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(monthTitle(for: visibleMonthStart))
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                            Image(systemName: isMonthYearPickerExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppTheme.neonGreen)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        shiftMonth(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                }
                .padding(.horizontal, 4)

                if isMonthYearPickerExpanded {
                    HStack(spacing: 8) {
                        Picker("statistics.calendar.month", selection: monthBinding) {
                            ForEach(1...12, id: \.self) { month in
                                Text(monthName(month))
                                    .tag(month)
                            }
                        }
                        .pickerStyle(.wheel)
                        .labelsHidden()

                        Picker("statistics.calendar.year", selection: yearBinding) {
                            ForEach(yearRange(), id: \.self) { year in
                                Text("\(year)")
                                    .tag(year)
                            }
                        }
                        .pickerStyle(.wheel)
                        .labelsHidden()
                    }
                    .frame(height: 160)
                    .padding(.horizontal, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 8) {
                    ForEach(weekdaySymbols(), id: \.self) { symbol in
                        Text(symbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }

                    ForEach(monthGridDates(), id: \.self) { date in
                        if let date {
                            calendarDayButton(date)
                        } else {
                            Color.clear.frame(height: 38)
                        }
                    }
                }
                .padding(.top, 2)

                Spacer()
            }
            .padding()
            .appScreenBackground()
            .navigationTitle(L10n.tr("statistics.calendar.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("statistics.calendar.close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func calendarDayButton(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isInVisibleMonth = calendar.isDate(date, equalTo: visibleMonthStart, toGranularity: .month)

        return Button {
            selectedDate = date
            dismiss()
        } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(
                    isSelected
                        ? Color.black.opacity(0.88)
                        : (isInVisibleMonth ? Color.white : Color.white.opacity(0.35))
                )
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? AppTheme.neonGreen : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    private func monthGridDates() -> [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: visibleMonthStart) else {
            return []
        }
        let start = monthInterval.start
        let numberOfDays = calendar.range(of: .day, in: .month, for: start)?.count ?? 0
        let firstWeekday = calendar.component(.weekday, from: start)
        let leadingPlaceholders = (firstWeekday - calendar.firstWeekday + 7) % 7

        var items: [Date?] = Array(repeating: nil, count: leadingPlaceholders)
        for day in 0..<numberOfDays {
            if let date = calendar.date(byAdding: .day, value: day, to: start) {
                items.append(date)
            }
        }
        return items
    }

    private func weekdaySymbols() -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        let symbols = formatter.shortStandaloneWeekdaySymbols ?? formatter.shortWeekdaySymbols ?? []
        guard !symbols.isEmpty else { return ["M", "T", "W", "T", "F", "S", "S"] }

        let first = max(0, calendar.firstWeekday - 1)
        return Array(symbols[first...] + symbols[..<first]).map { $0.uppercased() }
    }

    private func shiftMonth(by delta: Int) {
        visibleMonthStart = calendar.date(byAdding: .month, value: delta, to: visibleMonthStart) ?? visibleMonthStart
    }

    private func monthTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: date).capitalized
    }

    private var monthBinding: Binding<Int> {
        Binding(
            get: { calendar.component(.month, from: visibleMonthStart) },
            set: { newMonth in
                updateVisibleMonth(month: newMonth, year: calendar.component(.year, from: visibleMonthStart))
            }
        )
    }

    private var yearBinding: Binding<Int> {
        Binding(
            get: { calendar.component(.year, from: visibleMonthStart) },
            set: { newYear in
                updateVisibleMonth(month: calendar.component(.month, from: visibleMonthStart), year: newYear)
            }
        )
    }

    private func updateVisibleMonth(month: Int, year: Int) {
        var components = calendar.dateComponents([.day], from: visibleMonthStart)
        components.month = month
        components.year = year
        components.day = 1
        visibleMonthStart = calendar.date(from: components) ?? visibleMonthStart
    }

    private func yearRange() -> [Int] {
        let currentYear = calendar.component(.year, from: Date())
        return Array((currentYear - 5)...(currentYear + 5))
    }

    private func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        let name = formatter.monthSymbols[max(0, min(month - 1, 11))]
        return name.capitalized
    }
}

#if canImport(DeviceActivity)
@available(iOS 26.0, *)
private struct DailyAppUsageReportCard: View {
    let reportInterval: DateInterval
    let selection: FamilyActivitySelection

    private var hasSelection: Bool {
        !selection.applicationTokens.isEmpty ||
            !selection.categoryTokens.isEmpty ||
            !selection.webDomainTokens.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasSelection {
                DeviceActivityReport(
                    .parentalControlDailyActivity,
                    filter: DeviceActivityFilter(
                        segment: .daily(during: reportInterval),
                        devices: .init([.iPhone, .iPad])
                    )
                )
                .frame(minHeight: 220, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Text("statistics.app_usage.empty_selection")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
    }
}

@available(iOS 26.0, *)
private extension DeviceActivityReport.Context {
    static let parentalControlDailyActivity = Self("parentalcontrol.daily-activity")
}
#endif

#Preview {
    StatisticsView()
        .environmentObject(AppState())
}
