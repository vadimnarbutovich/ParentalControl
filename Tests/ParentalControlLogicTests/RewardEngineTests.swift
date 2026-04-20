import Testing
@testable import ParentalControlLogic

@Test
func stepRewardsEarnExpectedSecondsAndProcessedSteps() {
    let engine = RewardEngine()
    let settings = ConversionSettings(stepsPerMinute: 100, squatsPerMinute: 5, pushUpsPerMinute: 5)
    let result = engine.stepSecondsEarned(currentSteps: 1275, lastProcessedSteps: 975, settings: settings)

    #expect(result.seconds == 180)
    #expect(result.newProcessedSteps == 1275)
}

@Test
func stepRewardsAreProportionalForSmallDelta() {
    let engine = RewardEngine()
    let settings = ConversionSettings(stepsPerMinute: 100, squatsPerMinute: 5, pushUpsPerMinute: 5)
    let result = engine.stepSecondsEarned(currentSteps: 1001, lastProcessedSteps: 1000, settings: settings)

    #expect(result.seconds == 0)
    #expect(result.newProcessedSteps == 1001)
}

@Test
func repRewardsUseConfiguredRatioInSeconds() {
    let engine = RewardEngine()
    let settings = ConversionSettings(stepsPerMinute: 100, squatsPerMinute: 5, pushUpsPerMinute: 8)
    let squatSeconds = engine.repSecondsEarned(reps: 24, type: .squat, settings: settings)
    let pushUpSeconds = engine.repSecondsEarned(reps: 24, type: .pushUp, settings: settings)

    #expect(squatSeconds == 288)
    #expect(pushUpSeconds == 180)
}
