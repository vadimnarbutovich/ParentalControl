import Foundation
import Testing
@testable import ParentalControlLogic

@Test
func legacyMinuteBalanceStillDecodes() throws {
    let data = Data(#"{"totalEarnedMinutes":12,"totalSpentMinutes":5}"#.utf8)
    let balance = try JSONDecoder().decode(MinuteBalance.self, from: data)
    #expect(balance.totalEarnedSeconds == 720)
    #expect(balance.totalSpentSeconds == 300)
    #expect(balance.availableSeconds == 420)
}

@Test
func legacyConversionSettingsStillDecode() throws {
    let data = Data(#"{"stepsPerMinute":100,"repsPerMinute":8}"#.utf8)
    let settings = try JSONDecoder().decode(ConversionSettings.self, from: data)
    #expect(settings.stepsPerMinute == 100)
    #expect(settings.squatsPerMinute == 8)
    #expect(settings.pushUpsPerMinute == 8)
    let roundTrip = try JSONDecoder().decode(ConversionSettings.self, from: JSONEncoder().encode(settings))
    #expect(roundTrip == settings)
}

@Test(arguments: ["steps", "squat", "pushUp", "focusSession", "parentAdjustment", "testAdjustment"])
func historicalLedgerSourcesRemainReadable(source: String) throws {
    let object: [String: Any] = [
        "id": "E36B9054-8A80-43A7-8450-121B51904736",
        "date": 0,
        "source": source,
        "deltaMinutes": 3,
        "note": "Historical entry"
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    let entry = try JSONDecoder().decode(ActivityLedgerEntry.self, from: data)
    #expect(entry.source.rawValue == source)
    #expect(entry.deltaSeconds == 180)
    let roundTrip = try JSONDecoder().decode(ActivityLedgerEntry.self, from: JSONEncoder().encode(entry))
    #expect(roundTrip.source == entry.source)
    #expect(roundTrip.deltaSeconds == entry.deltaSeconds)
}
