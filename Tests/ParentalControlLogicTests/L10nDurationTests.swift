import Testing
@testable import ParentalControlLogic

@Test
func durationUsesMinutesForZeroAndNegativeValues() {
    let format = L10n.tr("unit.minutes.short")
    let expected = format == "unit.minutes.short" ? "0m" : L10n.f("unit.minutes.short", 0)
    #expect(L10n.duration(seconds: 0) == expected)
    #expect(L10n.duration(seconds: -1) == expected)
}

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
