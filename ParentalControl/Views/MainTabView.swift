import SwiftUI

private enum MainTab: String, CaseIterable {
    case home
    case statistics
    case blocklist
    case settings
}

struct MainTabView: View {
    @State private var selectedTab: MainTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem {
                    Label("tab.dashboard", systemImage: "square.grid.2x2.fill")
                }
                .tag(MainTab.home)

            StatisticsView()
                .tabItem {
                    Label("tab.statistics", systemImage: "chart.bar.fill")
                }
                .tag(MainTab.statistics)

            BlockListView()
                .tabItem {
                    Label("tab.block", systemImage: "checklist")
                }
                .tag(MainTab.blocklist)

            SettingsView()
                .tabItem {
                    Label("tab.settings", systemImage: "gearshape.fill")
                }
                .tag(MainTab.settings)
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedTab) { _, newValue in
            AppAnalytics.report("main_tab_select", parameters: ["tab": newValue.rawValue])
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppState())
        .environmentObject(SubscriptionService())
}
