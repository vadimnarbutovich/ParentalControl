import CoreLocation
import SwiftUI

struct OnboardingFlowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var screenTimeService: ScreenTimeService

    /// Если задан — просмотр из настроек: на последнем шаге вызывается колбэк вместо `completeOnboarding()`.
    var onReplayFinished: (() -> Void)? = nil

    @State private var step = 0
    @State private var isAdvancing = false
    @State private var stepsText = ""
    @State private var squatsText = ""
    @State private var pushUpsText = ""
    @State private var confettiTrigger = 0

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
        /// Компактная вёрстка шага «Фокус-сессия»: больше ширина под текст, меньше вертикальные зазоры.
        static let focusSessionTopSpacer: CGFloat = 8
        static let focusSessionTextHorizontalInset: CGFloat = 12
        static let focusSessionTextToImagesTop: CGFloat = 4
        static let focusSessionBetweenImages: CGFloat = 4
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
            syncConversionFieldsFromState()
            let mode = onReplayFinished == nil ? "first_launch" : "replay"
            AppAnalytics.report("onboarding_flow_shown", parameters: ["mode": mode])
        }
        .task {
            await appState.refreshPermissionStatuses()
        }
    }

    private var primaryButtonTitleKey: LocalizedStringKey {
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
                welcomePage(contentSize: size)
            case 1:
                conversionPage(contentSize: size)
            case 2:
                focusSessionPage(contentSize: size)
            case 3:
                heroTextPage(
                    titleKey: "onboarding.health.title",
                    bodyKey: "onboarding.health.body",
                    assetName: "health",
                    iconGlowColor: AppTheme.neonBlue,
                    contentSize: size
                )
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
                    bodyKey: "onboarding.notifications.body",
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

    private func conversionPage(contentSize: CGSize) -> some View {
        let compact = contentSize.height < 640
        let thumb: CGFloat = compact ? 56 : 72
        let fieldSpacing: CGFloat = compact ? 10 : 14
        let titleSize: CGFloat = compact ? 28 : 32
        let subtitleSize: CGFloat = compact ? 16 : 18
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: compact ? 10 : 14) {
                VStack(spacing: OnboardingLayout.onboardingTitleToBodySpacing) {
                    Text("onboarding.conversion.title")
                        .font(.system(size: titleSize, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                        .minimumScaleFactor(0.78)
                        .lineLimit(2)

                    Text("onboarding.conversion.subtitle")
                        .font(.system(size: subtitleSize, weight: .medium, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.88))
                        .minimumScaleFactor(0.82)
                        .lineLimit(3)
                        .padding(.horizontal, 10)
                }

                HStack(spacing: compact ? 14 : 20) {
                    onboardingActivityThumb(asset: "walk", tint: AppTheme.neonBlue, side: thumb)
                    onboardingActivityThumb(asset: "squat", tint: AppTheme.neonGreen, side: thumb)
                    onboardingActivityThumb(asset: "pushups", tint: Color.orange.opacity(0.95), side: thumb)
                }
                .padding(.vertical, compact ? 4 : 8)

                VStack(alignment: .leading, spacing: fieldSpacing) {
                    conversionField("settings.conversion.steps.per.minute", text: $stepsText, compact: compact)
                    conversionField("settings.conversion.squats.per.minute", text: $squatsText, compact: compact)
                    conversionField("settings.conversion.pushups.per.minute", text: $pushUpsText, compact: compact)
                }
                .padding(.horizontal, 6)

                Button("settings.conversion.reset.defaults") {
                    let d = ConversionSettings.default
                    stepsText = "\(d.stepsPerMinute)"
                    squatsText = "\(d.squatsPerMinute)"
                    pushUpsText = "\(d.pushUpsPerMinute)"
                }
                .font(.system(size: compact ? 15 : 16, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.neonBlue)
                .padding(.top, 2)
            }
            .padding(.horizontal, 22)
            Spacer(minLength: 0)
        }
        .frame(width: contentSize.width, height: contentSize.height)
    }

    private func onboardingActivityThumb(asset: String, tint: Color, side: CGFloat) -> some View {
        Image(asset)
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
            .shadow(color: tint.opacity(0.45), radius: 14, y: 2)
    }

    private func conversionField(_ titleKey: String, text: Binding<String>, compact: Bool) -> some View {
        let vPad: CGFloat = compact ? 8 : 12
        let titleFont: CGFloat = compact ? 14 : 15
        let valueFont: CGFloat = compact ? 20 : 22
        return VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: titleFont, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            TextField("", text: text)
                .keyboardType(.numberPad)
                .font(.system(size: valueFont, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, vPad)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(AppTheme.glassBorder.opacity(0.4), lineWidth: 1)
                        )
                )
        }
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

    private func focusSessionPage(contentSize: CGSize) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: OnboardingLayout.onboardingTitleToBodySpacing) {
                Text("onboarding.focus.title")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                    .minimumScaleFactor(0.72)
                    .lineLimit(2)

                Text("onboarding.focus.body")
                    .font(.system(size: 19, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(2)
                    .minimumScaleFactor(0.68)
                    .lineLimit(8)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, OnboardingLayout.focusSessionTextHorizontalInset)
            .padding(.top, OnboardingLayout.focusSessionTopSpacer)
            .fixedSize(horizontal: false, vertical: true)

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let firstWidth = w * 0.75
                let firstCap = h * 0.56
                let imagesGap = OnboardingLayout.focusSessionBetweenImages
                let secondCap = max(h * 0.44, h - firstCap - imagesGap)
                VStack(alignment: .leading, spacing: imagesGap) {
                    Image("focusSession")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: firstWidth, maxHeight: firstCap, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(
                            UnevenRoundedRectangle(
                                cornerRadii: .init(
                                    topLeading: 0,
                                    bottomLeading: 0,
                                    bottomTrailing: 18,
                                    topTrailing: 18
                                ),
                                style: .continuous
                            )
                        )
                        .shadow(color: AppTheme.neonBlue.opacity(0.35), radius: 18, y: 4)

                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Image("focusTime")
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(maxWidth: w * 0.6)
                            .frame(maxHeight: secondCap, alignment: .center)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: AppTheme.neonGreen.opacity(0.35), radius: 18, y: 4)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(width: w, height: h, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, OnboardingLayout.focusSessionTextToImagesTop)
        }
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

                Text("onboarding.done.body")
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
            ForEach(0..<9, id: \.self) { index in
                Circle()
                    .fill(index == step ? AppTheme.neonGreen : Color.white.opacity(0.22))
                    .frame(width: index == step ? 8 : 6, height: index == step ? 8 : 6)
            }
        }
    }

    private func syncConversionFieldsFromState() {
        let s = appState.settings
        stepsText = "\(s.stepsPerMinute)"
        squatsText = "\(s.squatsPerMinute)"
        pushUpsText = "\(s.pushUpsPerMinute)"
    }

    private func saveConversionForOnboarding() {
        let def = ConversionSettings.default
        let steps = Int(stepsText).flatMap { $0 > 0 ? $0 : nil } ?? def.stepsPerMinute
        let squats = Int(squatsText).flatMap { $0 > 0 ? $0 : nil } ?? def.squatsPerMinute
        let pushUps = Int(pushUpsText).flatMap { $0 > 0 ? $0 : nil } ?? def.pushUpsPerMinute
        appState.updateSettings(
            ConversionSettings(stepsPerMinute: steps, squatsPerMinute: squats, pushUpsPerMinute: pushUps)
        )
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
                step = 1
            case 1:
                saveConversionForOnboarding()
                step = 2
            case 2:
                step = 3
            case 3:
                if !appState.isHealthAuthorized {
                    await appState.requestHealthAccessOnly()
                }
                await appState.refreshPermissionStatuses()
                step = 4
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
                step = 6
            case 6:
                // Двухэтапный запрос геолокации:
                // 1) When-in-Use — обязателен, без него Apple не покажет диалог Always;
                // 2) Always — нужен, чтобы снять координату, когда приложение свёрнуто/выгружено
                //    из памяти. Мы НЕ держим GPS постоянно — фоновые апдейты включаются строго
                //    on-demand на момент одного capture (см. LocationService).
                let whenInUse = await appState.requestChildLocationPermissionIfNeeded()
                if whenInUse == .authorizedWhenInUse || whenInUse == .authorizedAlways {
                    _ = await appState.requestChildLocationAlwaysAuthorizationIfNeeded()
                }
                step = 7
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
