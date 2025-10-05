import Foundation

/// User-modifiable preferences persisted separately from runtime state.
/// These override defaults in `AppConfig` via `ConfigProvider`.
struct UserPreferences: Codable, Equatable {
    var dailyHour: Int?
    var dailyMinute: Int?
    var warningOffsets: [Int]? // seconds before shutdown

    init(dailyHour: Int? = nil, dailyMinute: Int? = nil, warningOffsets: [Int]? = nil) {
        self.dailyHour = dailyHour
        self.dailyMinute = dailyMinute
        self.warningOffsets = warningOffsets
    }
}

/// Abstraction for loading/saving user preferences.
protocol PreferencesStore {
    func load() -> UserPreferences
    func save(_ prefs: UserPreferences)
}

final class FilePreferencesStore: PreferencesStore {
    private let fileURL: URL
    private let fm = FileManager.default
    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("preferences.json")
    }
    func load() -> UserPreferences {
        guard let data = try? Data(contentsOf: fileURL) else { return UserPreferences() }
        return (try? JSONDecoder().decode(UserPreferences.self, from: data)) ?? UserPreferences()
    }
    func save(_ prefs: UserPreferences) {
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Provides the current effective `AppConfig` by combining base defaults and user preferences at read time.
protocol ConfigProviding: AnyObject {
    var current: AppConfig { get }
    func update(_ transform: (inout UserPreferences) -> Void)
}

final class ConfigProvider: ConfigProviding {
    private let base: AppConfig
    private let prefsStore: PreferencesStore
    private var prefs: UserPreferences
    private let queue = DispatchQueue(label: "config.provider.queue", qos: .userInitiated)

    init(base: AppConfig, prefsStore: PreferencesStore) {
        self.base = base
        self.prefsStore = prefsStore
        self.prefs = prefsStore.load()
    }

    var current: AppConfig {
        // Merge overrides: if user sets warningOffsets they fully replace defaults.
        let hour = prefs.dailyHour ?? base.dailyHour
        let minute = prefs.dailyMinute ?? base.dailyMinute
        let warning = prefs.warningOffsets?.filter { $0 > 0 }.sorted(by: >) ?? base.defaultWarningOffsets
        return AppConfig(
            dailyHour: hour,
            dailyMinute: minute,
            defaultPostponeIntervalSeconds: base.defaultPostponeIntervalSeconds,
            defaultMaxPostpones: base.defaultMaxPostpones,
            defaultWarningOffsets: warning,
            options: base.options // runtime command-line flags remain as originally parsed
        )
    }

    func update(_ transform: (inout UserPreferences) -> Void) {
        queue.sync {
            var mutable = prefs
            transform(&mutable)
            prefs = mutable
            prefsStore.save(prefs)
        }
    }
}
