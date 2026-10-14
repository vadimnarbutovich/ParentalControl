import CoreLocation
import SwiftUI

struct OnboardingFlowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var screenTimeService: ScreenTimeService

    /// Если задан — просмотр из настроек: на последнем шаге вызывается колбэк вместо `completeOnboarding()`.
    var onReplayFinished: (() -> Void)? = nil

    @State private var step = 0
    @State private var isAdvancing = false
    @State private var confettiTrigger = 0
    @State private var didRequestLocationAccess = false
    @State private var showLocationSettingsHint = false

    /// Горизонтальный отступ контента онбординга — совпадает с кнопкой «Далее» / «Начать».
    private enum OnboardingLayout {
        /// Зазор между заголовком и текстом под ним на всех шагах онбординга.
        static let onboardingTitleToBodySpacing: CGFloat = 16
        static let horizontalInset: CGFloat = 20
        /// Здоровье, экранное время, уведомления, приложения (база 132 pt, +⅓).
        static let onboardingStepIconSize: CGFloat = 176
        /// Иллюстрация ButtonGo на финале (+⅓ к прежним 300×(132×1.35)).
        static let finalGoIllustrationMaxWidth: CGFloat = 300 * 4 / 3
        static let finalGoIllustrationMaxHeight: CGFloat = 132 * 1.35 * 4 / 3
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AppBackgroundView()

            VStack(spacing: 0) {
                GeometryReader { geo in
                    onboardingStepContent(size: geo.size)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                pageIndicator
                    .padding(.bottom, 12)

                Button(action: handleBottomBarPrimaryTap) {
                    Text(primaryButtonTitleKey)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NeonPrimaryButtonStyle(tint: step == 8 ? AppTheme.neonBlue : AppTheme.neonGreen))
                .disabled(isAdvancing)
                .opacity(isAdvancing ? 0.55 : 1)
                .padding(.horizontal, OnboardingLayout.horizontalInset)
                .padding(.bottom, 28)
            }
        }
        .onChange(of: step) { _, newValue in
            if newValue == 8 {
                confettiTrigger += 1
            }
        }
        .onAppear {
            let mode = onReplayFinished == nil ? "first_launch" : "replay"
            AppAnalytics.report("onboarding_flow_shown", parameters: ["mode": mode])
        }
        .task {
            await appState.refreshPermissionStatuses()
        }
        .alert("onboarding.location.title", isPresented: $showLocationSettingsHint) {
            Button("permission.banner.open_settings") { appState.openAppSettingsURL() }
            Button("location.setup.later", role: .cancel) { step = 7 }
        } message: {
            Text("location.settings.description")
        }
    }

    private var primaryButtonTitleKey: LocalizedStringKey {
        if step == 6 && !didRequestLocationAccess {
            return "location.setup.allow"
        }
        if step == 8 {
            return "onboarding.cta.start"
        }
        return "onboarding.cta.next"
    }

    @ViewBuilder
    private func onboardingStepContent(size: CGSize) -> some View {
        Group {
            switch step {
            case 0:
                heroTextPage(titleKey: "budget.onboarding_title", bodyKey: "budget.onboarding_body", assetName: "timer", iconGlowColor: AppTheme.neonBlue, contentSize: size)
            case 4:
                heroTextPage(
                    titleKey: "onboarding.screentime.title",
                    bodyKey: "onboarding.screentime.body",
                    assetName: "timer",
                    iconGlowColor: AppTheme.neonBlue,
                    contentSize: size
                )
            case 5:
                heroTextPage(
                    titleKey: "onboarding.notifications.title",
                    bodyKey: appState.deviceRole == .parent ? "permission.notifications.parent.body" : "permission.notifications.child.body",
                    assetName: "notification",
                    iconGlowColor: AppTheme.neonGreen,
                    contentSize: size
                )
            case 6:
                heroTextPage(
                    titleKey: "onboarding.location.title",
                    bodyKey: "onboarding.location.body",
                    assetName: "location",
                    iconGlowColor: AppTheme.neonBlue,
                    contentSize: size
                )
            case 7:
                appsPage(contentSize: size)
            case 8:
                finalPage(contentSize: size)
            default:
                welcomePage(contentSize: size)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.22), value: step)
    }

    private func welcomePage(contentSize: CGSize) -> some View {
        let maxHero = min(380, contentSize.height * 0.5)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: OnboardingLayout.onboardingTitleToBodySpacing) {
                Text("onboarding.welcome.title")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .minimumScaleFactor(0.72)
                    .lineLimit(3)

                Text("onboarding.welcome.subtitle")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.9))
                    .minimumScaleFactor(0.72)
                    .lineLimit(5)
            }
            .padding(.horizontal, OnboardingLayout.horizontalInset)

            Image("onboardingHero")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: maxHero)
                .shadow(color: AppTheme.neonBlue.opacity(0.25), radius: 28, y: 8)
                .padding(.horizontal, OnboardingLayout.horizontalInset)
                .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .frame(width: contentSize.width, height: contentSize.height)
    }

    private func heroTextPage(
        titleKey: String,
        bodyKey: String,
        assetName: String,
        iconGlowColor: Color,
        contentSize: CGSize
    ) -> some View {
        let iconSide = min(
            OnboardingLayout.onboardingStepIconSize,
            contentSize.width * 0.46,
            contentSize.height * 0.34
        )
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                .minimumScaleFactor(0.7)
                .lineLimit(3)
                .padding(.horizontal, 12)

            Text(LocalizedStringKey(bodyKey))
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.92))
                .lineSpacing(3)
                .minimumScaleFactor(0.7)
                .lineLimit(7)
                .padding(.horizontal, 16)
                .padding(.top, OnboardingLayout.onboardingTitleToBodySpacing)

            Image(assetName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: iconSide, height: iconSide)
                .shadow(color: iconGlowColor.opacity(0.45), radius: 28, y: 0)
                .padding(.top, 10)

            Spacer(minLength: 0)
        }
        .frame(width: contentSize.width, height: contentSize.height)
    }

    private func appsPage(contentSize: CGSize) -> some View {
        let iconSide = min(
            OnboardingLayout.onboardingStepIconSize,
            contentSize.width * 0.46,
            contentSize.height * 0.32
        )
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("onboarding.apps.title")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                .minimumScaleFactor(0.72)
                .lineLimit(3)
                .padding(.horizontal, 12)

            Text("onboarding.apps.body.hint")
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.9))
                .lineSpacing(3)
                .minimumScaleFactor(0.72)
                .lineLimit(6)
                .padding(.horizontal, 14)
                .padding(.top, OnboardingLayout.onboardingTitleToBodySpacing)

            Image("apps")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: iconSide, height: iconSide)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: AppTheme.neonGreen.opacity(0.4), radius: 24, y: 0)
                .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(width: contentSize.width, height: contentSize.height)
    }

    private func finalPage(contentSize: CGSize) -> some View {
        let maxGoW = min(OnboardingLayout.finalGoIllustrationMaxWidth, contentSize.width - 24)
        let maxGoH = min(OnboardingLayout.finalGoIllustrationMaxHeight, contentSize.height * 0.34)
        return ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text("onboarding.done.title")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                    .minimumScaleFactor(0.75)
                    .lineLimit(2)
                    .padding(.horizontal, 12)

                Text("budget.onboarding_body")
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(3)
                    .minimumScaleFactor(0.72)
                    .lineLimit(5)
                    .padding(.horizontal, 14)
                    .padding(.top, OnboardingLayout.onboardingTitleToBodySpacing)

                Button(action: handleButtonGoTap) {
                    Image("ButtonGo")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: maxGoW)
                        .frame(maxHeight: maxGoH)
                        .shadow(color: AppTheme.neonGreen.opacity(0.4), radius: 24, y: 4)
                }
                .buttonStyle(.plain)
                .disabled(isAdvancing)
                .opacity(isAdvancing ? 0.55 : 1)
                .accessibilityLabel(Text("onboarding.cta.start"))
                .padding(.top, 10)

                Spacer(minLength: 0)
            }
            .frame(width: contentSize.width, height: contentSize.height)

            CelebrationConfettiView(trigger: confettiTrigger)
                .allowsHitTesting(false)
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 7) {
            ForEach(appState.deviceRole == .parent ? [0, 5, 8] : [0, 4, 5, 6, 7, 8], id: \.self) { index in
                Circle()
                    .fill(index == step ? AppTheme.neonGreen : Color.white.opacity(0.22))
                    .frame(width: index == step ? 8 : 6, height: index == step ? 8 : 6)
            }
        }
    }

    private func completeOnboardingExit() {
        let mode = onReplayFinished == nil ? "first_launch" : "replay"
        AppAnalytics.report("onboarding_closed", parameters: ["mode": mode])
        if let onReplayFinished {
            onReplayFinished()
        } else {
            appState.completeOnboarding()
        }
    }

    private func handleButtonGoTap() {
        guard step == 8 else { return }
        Task {
            isAdvancing = true
            defer { isAdvancing = false }
            completeOnboardingExit()
        }
    }

    private func handleBottomBarPrimaryTap() {
        performPrimaryAdvance()
    }

    private func performPrimaryAdvance() {
        Task {
            isAdvancing = true
            defer { isAdvancing = false }
            switch step {
            case 0:
                step = appState.deviceRole == .parent ? 5 : 4
            case 4:
                if !screenTimeService.isAuthorized {
                    await appState.requestScreenTimeAccessOnly()
                } else {
                    screenTimeService.refreshAuthorizationStatus()
                }
                step = 5
            case 5:
                if !appState.isNotificationAuthorized {
                    await appState.requestNotificationAccessOnly()
                }
                await appState.refreshPermissionStatuses()
                step = appState.deviceRole == .parent ? 8 : 6
            case 6:
                appState.refreshChildLocationAuthorizationStatus()
                if appState.childLocationAuthorizationStatus == .authorizedAlways {
                    step = 7
                    return
                }
                // Do not advance behind an outstanding system prompt or repeatedly request it.
                // The next tap checks the user's actual choice; Settings is the fallback.
                if didRequestLocationAccess {
                    showLocationSettingsHint = true
                    return
                }
                didRequestLocationAccess = true
                let whenInUse = await appState.requestChildLocationPermissionIfNeeded()
                if whenInUse == .authorizedWhenInUse {
                    _ = await appState.requestChildLocationAlwaysAuthorizationIfNeeded()
                } else if whenInUse == .denied || whenInUse == .restricted {
                    showLocationSettingsHint = true
                }
            case 7:
                step = 8
            case 8:
                completeOnboardingExit()
            default:
                break
            }
        }
    }
}
