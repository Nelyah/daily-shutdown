import XCTest
@testable import DailyShutdown

final class ConfigProviderTests: XCTestCase {
    private final class MemoryPrefs: PreferencesStore {
        var stored = UserPreferences()
        func load() -> UserPreferences { stored }
        func save(_ prefs: UserPreferences) { stored = prefs }
    }

    func testMergesBaseAndPrefs() {
        let base = AppConfig(
            dailyHour: 18,
            dailyMinute: 0,
            defaultPostponeIntervalSeconds: 900,
            defaultMaxPostpones: 3,
            defaultWarningOffsets: [900,300,60],
            options: RuntimeOptions()
        )
        let store = MemoryPrefs()
        store.stored = UserPreferences(dailyHour: 20, dailyMinute: 30, warningOffsets: [600,120])
        let provider = ConfigProvider(base: base, prefsStore: store)
        let effective = provider.current
        XCTAssertEqual(effective.dailyHour, 20)
        XCTAssertEqual(effective.dailyMinute, 30)
        XCTAssertEqual(effective.defaultWarningOffsets, [600,120])
    }

    func testUpdatePersists() {
        let base = AppConfig(
            dailyHour: 18,
            dailyMinute: 0,
            defaultPostponeIntervalSeconds: 900,
            defaultMaxPostpones: 3,
            defaultWarningOffsets: [900,300,60],
            options: RuntimeOptions()
        )
        let store = MemoryPrefs()
        let provider = ConfigProvider(base: base, prefsStore: store)
        provider.update { $0.warningOffsets = [1800, 600] }
        XCTAssertEqual(provider.current.defaultWarningOffsets, [1800,600])
        // Ensure stored in backing store
        XCTAssertEqual(store.stored.warningOffsets, [1800,600])
    }
}
