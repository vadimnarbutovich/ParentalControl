import Foundation

struct RewardEngine {
    func stepSecondsEarned(
        currentSteps: Int,
        lastProcessedSteps: Int,
        settings: ConversionSettings
    ) -> (seconds: Int, newProcessedSteps: Int) {
        guard settings.stepsPerMinute > 0 else { return (0, lastProcessedSteps) }
        guard currentSteps > lastProcessedSteps else {
            return (0, currentSteps)
        }

        let delta = currentSteps - lastProcessedSteps
        let earned = (delta * 60) / settings.stepsPerMinute
        return (earned, currentSteps)
    }

    func repSecondsEarned(reps: Int, type: ExerciseType, settings: ConversionSettings) -> Int {
        let repsPerMinute = settings.repsPerMinute(for: type)
        guard repsPerMinute > 0 else { return 0 }
        return (reps * 60) / repsPerMinute
    }
}
