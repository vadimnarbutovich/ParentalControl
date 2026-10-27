import MapKit
import SwiftUI

/// Вкладка «Карта» для родителя. Pull-flow: при нажатии «Обновить местоположение»
/// бэкенд шлёт alert push на ребёнка, тот снимает GPS fix и записывает в БД,
/// а родитель пуллит свежее значение и отображает его на карте.
struct MapTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var refreshTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView(usesSharedCanvas: true)
                content
            }
            .navigationTitle("map.title")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .task {
            await appState.loadChildLocationIfNeeded()
            recenterCameraIfPossible(animated: false)
        }
        .onChange(of: appState.childLocationSnapshot) { _, _ in
            recenterCameraIfPossible(animated: true)
        }
        .onDisappear { refreshTask?.cancel() }
        .onChange(of: appState.isFamilyAccessAllowed) { _, allowed in
            if !allowed { refreshTask?.cancel() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { refreshTask?.cancel() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if appState.pairingState?.isLinked != true {
            unpairedState
        } else {
            VStack(spacing: 12) {
                mapBody
                refreshButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
    }

    private var mapBody: some View {
        ZStack {
            Map(position: $cameraPosition) {
                if let snapshot = appState.childLocationSnapshot {
                    Annotation(
                        L10n.tr("map.title"),
                        coordinate: snapshot.coordinate,
                        // The PNG has transparent margins. Anchor the visible pin tip,
                        // measured at pixel (117, 232) in the 240 x 240 asset.
                        anchor: UnitPoint(x: 117.0 / 240.0, y: 232.0 / 240.0)
                    ) {
                        Image("childLocationMarker")
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                            .accessibilityLabel(Text("map.title"))
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard)

            if appState.childLocationSnapshot == nil {
                emptyOverlay
            }

            VStack {
                Spacer()
                if let snapshot = appState.childLocationSnapshot {
                    locationStatusCard(snapshot: snapshot)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    private var refreshButton: some View {
        Button {
            guard refreshTask == nil, !appState.isParentRefreshingChildLocation else { return }
            refreshTask = Task {
                await appState.refreshChildLocationFromParent()
                refreshTask = nil
            }
        } label: {
            HStack(spacing: 8) {
                if appState.isParentRefreshingChildLocation {
                    ProgressView()
                        .tint(.white)
                    Text("map.refreshing")
                } else {
                    Image(systemName: "location.fill")
                    Text("map.refresh")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
        .disabled(appState.isParentRefreshingChildLocation)
        .opacity(appState.isParentRefreshingChildLocation ? 0.7 : 1)
    }

    private func locationStatusCard(snapshot: ChildLocationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(L10n.f("map.last_seen", relativeString(from: snapshot.capturedAt, relativeTo: context.date)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            if let accuracy = snapshot.horizontalAccuracy, accuracy > 0 {
                Text(L10n.f("map.accuracy", Int(accuracy.rounded())))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
            }
            if appState.isFamilyAccessAllowed, let message = appState.parentLocationStatusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.neonOrange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.55))
        )
    }

    private var emptyOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("map.empty.title")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("map.empty.subtitle")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if appState.isFamilyAccessAllowed, let message = appState.parentLocationStatusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.neonOrange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(0.55))
        )
        .padding(.horizontal, 20)
    }

    private var unpairedState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "iphone.gen3.slash")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("map.unpaired.title")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("map.unpaired.subtitle")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
    }

    private func recenterCameraIfPossible(animated: Bool) {
        guard let snapshot = appState.childLocationSnapshot else { return }
        let region = MKCoordinateRegion(
            center: snapshot.coordinate,
            latitudinalMeters: 600,
            longitudinalMeters: 600
        )
        if animated {
            withAnimation(.easeInOut(duration: 0.4)) {
                cameraPosition = .region(region)
            }
        } else {
            cameraPosition = .region(region)
        }
    }

    private func relativeString(from date: Date, relativeTo now: Date) -> String {
        // Child and parent clocks can differ. A future timestamp must not
        // turn the last update into a prediction ("in 11 seconds").
        let elapsed = max(0, now.timeIntervalSince(date))
        guard elapsed >= 60 else { return L10n.tr("map.just_now") }

        // Explicit whole units prevent seconds and rounding up to the next minute.
        let components: DateComponents
        if elapsed >= 86_400 {
            components = DateComponents(day: -Int(elapsed / 86_400))
        } else if elapsed >= 3_600 {
            components = DateComponents(hour: -Int(elapsed / 3_600))
        } else {
            components = DateComponents(minute: -Int(elapsed / 60))
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? Locale.current.identifier)
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(from: components)
    }
}

private extension ChildLocationSnapshot {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
