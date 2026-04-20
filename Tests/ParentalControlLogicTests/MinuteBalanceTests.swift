import Testing
@testable import ParentalControlLogic

@Test
func availableSecondsNeverGoesBelowZero() {
    let balance = MinuteBalance(totalEarnedSeconds: 50, totalSpentSeconds: 90)
    #expect(balance.availableSeconds == 0)
}
