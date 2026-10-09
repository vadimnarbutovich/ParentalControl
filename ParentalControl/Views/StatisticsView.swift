import SwiftUI

/// Remote parent report. No local Screen Time report and no polling loop.
struct StatisticsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var period = 7
    @State private var endDay: String?
    @State private var selectedDay: String?
    @State private var report: ParentStatisticsReport?
    @State private var loading = false
    @State private var failed = false
    @State private var visible = false
    @State private var requestID = UUID()
    @State private var calendarPresented = false
    @State private var calendarDate = Date()

    private var requestKey: String {
        "\(appState.pairingState?.familyID.uuidString ?? "unlinked"):\(period):\(endDay ?? appState.parentBudgetStatus?.policy?.extraDay ?? "current"):\(visible):\(scenePhase == .active)"
    }
    private var selected: ParentStatisticsDay? { report?.days.first { $0.day == selectedDay } ?? report?.days.last }
    private var knownDays: [ParentStatisticsDay] { report?.days.filter { $0.usedSeconds != nil } ?? [] }
    private var totalUsed: Int { knownDays.reduce(0) { $0 + ($1.usedSeconds ?? 0) } }
    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = .gmt
        return c
    }
    private var today: Date { ParentStatisticsDay.date(report?.today ?? "") ?? Date() }
    private var earliest: Date { utcCalendar.date(byAdding: .day, value: -89, to: today) ?? today }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if appState.pairingState?.isLinked != true {
                        Text("reports.unlinked").foregroundStyle(.secondary)
                    } else {
                        periodPicker
                        if loading && report == nil { ProgressView().frame(maxWidth: .infinity).padding(40) }
                        if failed {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("reports.error").foregroundStyle(.secondary)
                                Button("reports.retry") { Task { await load(force: true) } }.disabled(loading)
                            }.padding(20).glassCard(cornerRadius: 22, glowColor: AppTheme.neonBlue)
                        }
                        if let report {
                            usageCard(report)
                            if let selected { dayCard(selected) }
                            tasksCard(report)
                            Text("reports.retention").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }.padding()
            }
            .scrollIndicators(.hidden)
            .appScreenBackground()
            .refreshable { await load(force: true) }
            .onAppear { visible = true }
            .onDisappear { visible = false; requestID = UUID(); loading = false }
            .onChange(of: appState.pairingState?.familyID) { _, _ in
                report = nil; selectedDay = nil; endDay = nil; requestID = UUID()
            }
            .onChange(of: appState.parentBudgetStatus?.state) { _, _ in
                if visible { report = report?.merging(appState.parentBudgetStatus) }
            }
            .onChange(of: appState.parentBudgetStatus?.policy) { _, _ in
                if visible { report = report?.merging(appState.parentBudgetStatus) }
            }
            .task(id: requestKey) {
                guard visible, scenePhase == .active else { return }
                await load()
            }
            .sheet(isPresented: $calendarPresented) { calendarSheet }
        }
    }

    private var calendarSheet: some View {
        NavigationStack {
            DatePicker("statistics.calendar.title", selection: $calendarDate,
                       in: earliest...today, displayedComponents: .date)
                .datePickerStyle(.graphical).environment(\.timeZone, .gmt)
                .padding().appScreenBackground()
                .navigationTitle(L10n.tr("statistics.calendar.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("statistics.calendar.close") {
                            let key = dayKey(calendarDate)
                            selectedDay = key
                            if report?.days.contains(where: { $0.day == key }) != true {
                                report = nil; endDay = key
                            }
                            calendarPresented = false
                        }
                    }
                }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("statistics.title").font(.largeTitle.bold())
                Text("reports.scope").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if loading && report != nil { ProgressView() }
            Button {
                calendarDate = selected?.date ?? today
                calendarPresented = true
                AppAnalytics.report("statistics_calendar_open")
            } label: {
                Image(systemName: "calendar").font(.headline).frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.12), in: Circle())
            }.buttonStyle(.plain).accessibilityLabel(Text("statistics.calendar.title")).disabled(report == nil)
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 8) {
            ForEach([7, 30], id: \.self) { count in
                Button {
                    guard period != count else { return }
                    period = count; report = nil
                    AppAnalytics.report("statistics_period_select", parameters: ["days": count])
                } label: {
                    Text(L10n.tr(count == 7 ? "reports.week" : "reports.month")).frame(maxWidth: .infinity)
                }.buttonStyle(NeonChipButtonStyle(isActive: period == count, tint: AppTheme.neonBlue))
            }
        }
    }

    private func usageCard(_ data: ParentStatisticsReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button { shiftPeriod(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 36, height: 36)
                }.disabled((data.days.first?.date ?? earliest) <= earliest)
                    .accessibilityLabel(Text("reports.previous"))
                Spacer(minLength: 4)
                Text(periodTitle(data)).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                Spacer(minLength: 4)
                Button { shiftPeriod(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 36, height: 36)
                }.disabled(data.days.last?.day == data.today)
                    .accessibilityLabel(Text("reports.next"))
            }.buttonStyle(.plain)
            row("reports.total", value: knownDays.isEmpty ? "—" : L10n.duration(seconds: totalUsed))
            row("reports.average", value: knownDays.isEmpty ? "—" : L10n.duration(seconds: totalUsed / knownDays.count))
            chart(data.days)
            Text("reports.missing_hint").font(.footnote).foregroundStyle(.secondary)
            if knownDays.count < data.days.count {
                Text(L10n.f("reports.coverage", knownDays.count, data.days.count)).font(.footnote).foregroundStyle(.secondary)
            }
            if data.days.contains(where: { $0.day == data.today }) {
                Text("reports.partial_today").font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(20).glassCard(cornerRadius: 24, glowColor: AppTheme.neonBlue)
    }

    private func chart(_ days: [ParentStatisticsDay]) -> some View {
        let maximum = max(60, days.compactMap(\.usedSeconds).max() ?? 60)
        return HStack(alignment: .bottom, spacing: days.count > 7 ? 3 : 8) {
            ForEach(days) { day in
                Button {
                    selectedDay = day.day
                    AppAnalytics.report("statistics_day_select", parameters: ["day": day.day])
                } label: {
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(day.usedSeconds == nil ? Color.white.opacity(0.15) : AppTheme.neonBlue)
                            .frame(height: max(4, CGFloat(day.usedSeconds ?? 0) / CGFloat(maximum) * 120))
                        if days.count <= 7 {
                            Text(String(utcCalendar.component(.day, from: day.date)))
                                .font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }.frame(maxWidth: .infinity).frame(height: 150).padding(.vertical, 4)
                        .background(day.day == selected?.day ? Color.white.opacity(0.10) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(Text(dateTitle(day.date)))
                    .accessibilityValue(Text(day.usedSeconds.map { L10n.duration(seconds: $0) } ?? L10n.tr("reports.no_data")))
            }
        }
    }

    private func dayCard(_ day: ParentStatisticsDay) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(dateTitle(day.date)).font(.title3.bold())
            if day.usedSeconds == nil { Text("reports.no_data").foregroundStyle(.secondary) }
            row("budget.used", value: duration(day.usedSeconds))
            row("budget.title", value: duration(day.limitSeconds))
            row("reports.rewards", value: duration(day.rewardSeconds))
            row("budget.granted", value: duration(day.grantedSeconds))
            row("reports.tasks", value: day.approvedTasks.map { String($0) } ?? "—")
            if let stamp = day.updatedAt, let date = parseTimestamp(stamp) {
                Text(L10n.f("reports.updated", date.formatted(date: .abbreviated, time: .shortened)))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if day.legacy { Text("reports.legacy").font(.footnote).foregroundStyle(.secondary) }
        }.padding(20).glassCard(cornerRadius: 24, glowColor: AppTheme.neonPurple)
    }

    private func tasksCard(_ data: ParentStatisticsReport) -> some View {
        let days = data.days.filter { $0.approvedTasks != nil && $0.rewardSeconds != nil }
        return VStack(alignment: .leading, spacing: 16) {
            Text("reports.tasks_period").font(.title3.bold())
            row("reports.tasks", value: days.isEmpty ? "—" : String(days.reduce(0) { $0 + ($1.approvedTasks ?? 0) }))
            row("reports.rewards", value: days.isEmpty ? "—" : L10n.duration(seconds: days.reduce(0) { $0 + ($1.rewardSeconds ?? 0) }))
            if days.count < data.days.count {
                Text(L10n.f("reports.coverage", days.count, data.days.count)).font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(20).glassCard(cornerRadius: 24, glowColor: AppTheme.neonGreen)
    }

    private func row(_ key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L10n.tr(key)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }.font(.subheadline)
    }
    private func duration(_ seconds: Int?) -> String { seconds.map { L10n.duration(seconds: $0) } ?? "—" }
    private func dateTitle(_ date: Date) -> String {
        let f = DateFormatter(); f.timeZone = .gmt; f.dateStyle = .medium
        return f.string(from: date)
    }
    private func dayKey(_ date: Date) -> String {
        let f = DateFormatter(); f.calendar = utcCalendar; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .gmt; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    private func periodTitle(_ data: ParentStatisticsReport) -> String {
        guard let first = data.days.first, let last = data.days.last else { return "—" }
        return dateTitle(first.date) + " – " + dateTitle(last.date)
    }
    private func parseTimestamp(_ value: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private func shiftPeriod(_ direction: Int) {
        guard let last = report?.days.last?.date,
              let date = utcCalendar.date(byAdding: .day, value: direction * period, to: last) else { return }
        endDay = date >= today ? nil : dayKey(max(date, earliest))
        report = nil; selectedDay = nil
    }
    @MainActor private func load(force: Bool = false) async {
        guard visible, appState.pairingState?.isLinked == true else { report = nil; return }
        let id = UUID(); requestID = id; loading = true; failed = false
        let key = requestKey
        if report == nil { report = appState.cachedParentStatistics(days: period, endDay: endDay) }
        let family = appState.pairingState?.familyID
        defer { if requestID == id { loading = false } }
        do {
            let result = try await appState.parentStatistics(days: period, endDay: endDay, force: force)
            guard !Task.isCancelled, requestID == id, key == requestKey,
                  family == appState.pairingState?.familyID else { return }
            report = result
            if !result.days.contains(where: { $0.day == selectedDay }) { selectedDay = result.days.last?.day }
        } catch is CancellationError {
            // Dismissed screen, changed range, or unlinked family.
        } catch {
            if !Task.isCancelled, requestID == id, key == requestKey { failed = true }
        }
    }
}
