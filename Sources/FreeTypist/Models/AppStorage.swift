import Foundation

/// Allows tests and development runs to keep their data separate from the user's profile.
enum AppStorage {
    static var defaults: UserDefaults {
        if let suite = ProcessInfo.processInfo.environment["FREETYPIST_DEFAULTS_SUITE"] {
            return UserDefaults(suiteName: suite)!
        }
        return .standard
    }

    static var isIsolated: Bool {
        ProcessInfo.processInfo.environment["FREETYPIST_DATA_DIRECTORY"] != nil
    }

    static var directory: URL {
        let directory: URL
        if let path = ProcessInfo.processInfo.environment["FREETYPIST_DATA_DIRECTORY"] {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FreeTypist", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
