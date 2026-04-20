import Testing
@testable import ParentalControlLogic

@Test
func durationUsesSecondsBelowOneMinute() {
    let value = L10n.duration(seconds: 45)
    #expect(value.contains("45"))
}

@Test
func durationUsesMinutesAtOrAboveOneMinute() {
    let value = L10n.duration(seconds: 130)
    #expect(value.contains("2"))
}
