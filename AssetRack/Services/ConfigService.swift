import Foundation
import FirebaseRemoteConfig
import Observation

/// App-wide flags from Firebase Remote Config. Reads always succeed: values start
/// at the in-app defaults, and a failed fetch leaves the last activated ones.
@Observable
final class ConfigService {
    static let shared = ConfigService()

    private enum Key {
        static let minSupportedVersion  = "min_supported_version"
        static let finnhubSearchEnabled = "finnhub_search_enabled"
        static let statementScanEnabled = "statement_scan_enabled"
    }

    private static let defaultMinSupportedVersion = "0"
    private static let defaultFinnhubSearchEnabled = true
    private static let defaultStatementScanEnabled = false

    /// Oldest app version still supported. Older versions get an update prompt.
    private(set) var minSupportedVersion = ConfigService.defaultMinSupportedVersion
    /// Kill switch for the Yahoo holding search, which goes through the Firebase proxy.
    private(set) var finnhubSearchEnabled = ConfigService.defaultFinnhubSearchEnabled
    private var remoteStatementScanEnabled = ConfigService.defaultStatementScanEnabled

    /// Whether to show bank statement scanning. Off until it's turned on remotely.
    var statementScanEnabled: Bool {
        #if DEBUG
        if debugForceStatementScan { return true }
        #endif
        return remoteStatementScanEnabled
    }

    #if DEBUG
    /// Local override for testing the feature with the remote flag off. Compiled
    /// out of Release builds, so it can't enable anything for real users.
    var debugForceStatementScan = UserDefaults.standard.bool(forKey: "debug_force_statement_scan") {
        didSet { UserDefaults.standard.set(debugForceStatementScan, forKey: "debug_force_statement_scan") }
    }
    #endif

    var isUpdateRequired: Bool {
        guard !DemoMode.sessionActive else { return false }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return Self.isVersion(current, olderThan: minSupportedVersion)
    }

    /// Call once at launch.
    @MainActor
    func fetchAndActivate() async {
        guard FirebaseBootstrap.isConfigured, !DemoMode.sessionActive else { return }
        let remoteConfig = RemoteConfig.remoteConfig()
        let settings = RemoteConfigSettings()
        #if DEBUG
        settings.minimumFetchInterval = 60
        #else
        settings.minimumFetchInterval = 12 * 60 * 60
        #endif
        remoteConfig.configSettings = settings
        remoteConfig.setDefaults([
            Key.minSupportedVersion:  Self.defaultMinSupportedVersion as NSString,
            Key.finnhubSearchEnabled: Self.defaultFinnhubSearchEnabled as NSNumber,
            Key.statementScanEnabled: Self.defaultStatementScanEnabled as NSNumber,
        ])
        do {
            _ = try await remoteConfig.fetchAndActivate()
        } catch {
            print("[ConfigService] Fetch failed, using last known values: \(error.localizedDescription)")
        }
        minSupportedVersion = remoteConfig.configValue(forKey: Key.minSupportedVersion).stringValue
        finnhubSearchEnabled = remoteConfig.configValue(forKey: Key.finnhubSearchEnabled).boolValue
        remoteStatementScanEnabled = remoteConfig.configValue(forKey: Key.statementScanEnabled).boolValue
    }

    /// Dotted numeric comparison where missing parts count as 0, so "1.0" equals
    /// "1.0.0". Anything unparseable is treated as not older: a bad remote value
    /// must never nag every user.
    static func isVersion(_ version: String, olderThan minimum: String) -> Bool {
        func parts(_ string: String) -> [Int]? {
            let pieces = string.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            return pieces.contains(nil) ? nil : pieces.compactMap { $0 }
        }
        guard let lhs = parts(version), let rhs = parts(minimum) else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
