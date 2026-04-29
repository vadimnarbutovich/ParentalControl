import MapKit
import SwiftUI

/// Вкладка «Карта» для родителя. Pull-flow: при нажатии «Обновить местоположение»
/// бэкенд шлёт alert push на ребёнка, тот снимает GPS fix и записывает в БД,
/// а родитель пуллит свежее значение и отображает его на карте.
struct MapTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView()
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
                    Annotation(L10n.tr("tab.dashboard"), coordinate: snapshot.coordinate) {
                        ZStack {
                            Circle()
                                .fill(AppTheme.neonBlue.opacity(0.25))
                                .frame(width: 44, height: 44)
                            Circle()
                                .fill(AppTheme.neonBlue)
                                .frame(width: 18, height: 18)
                                .shadow(color: AppTheme.neonBlue.opacity(0.6), radius: 8)
                        }
                    }
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
            Task { await appState.refreshChildLocationFromParent() }
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
            Text(L10n.f("map.last_seen", relativeString(from: snapshot.capturedAt)))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            if let accuracy = snapshot.horizontalAccuracy, accuracy > 0 {
                Text(L10n.f("map.accuracy", Int(accuracy.rounded())))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
            }
            if let message = appState.parentLocationStatusMessage {
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
            if let message = appState.parentLocationStatusMessage {
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

    private func relativeString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private extension ChildLocationSnapshot {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
