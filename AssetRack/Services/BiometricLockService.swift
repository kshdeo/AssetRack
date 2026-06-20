import LocalAuthentication
import SwiftUI

@MainActor
@Observable
final class BiometricLockService {

    // Persisted preference. Lock takes effect on the next background→foreground
    // cycle — enabling it doesn't lock the user out mid-session.
    var isEnabled: Bool = UserDefaults.standard.bool(forKey: "biometricLockEnabled") {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "biometricLockEnabled") }
    }

    private(set) var isLocked: Bool = false
    private(set) var biometryType: LABiometryType = .none
    private(set) var authError: String?

    // True if the device has at least a passcode set. If false, enabling the
    // lock would trap the user and we disable the toggle.
    private(set) var canUseLock: Bool = false

    // Timestamp of the most recent background event. Nil on cold launch,
    // which is how we distinguish "never ran before" from "was backgrounded".
    private var backgroundedAt: Date?

    // Re-auth is skipped if the app returns within this window.
    private let gracePeriod: TimeInterval = 60

    init() {
        refreshCapabilities()
        if isEnabled { isLocked = true }   // cold launch always locks
    }

    func refreshCapabilities() {
        let context = LAContext()
        var error: NSError?
        canUseLock = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        biometryType = context.biometryType
    }

    /// Call when the app moves to background. Records the timestamp so the
    /// grace-period check on the next foreground has a reference point.
    func noteBackground() {
        guard isEnabled else { return }
        backgroundedAt = Date()
    }

    /// Call when the app becomes active. Locks and prompts for auth only if:
    ///  - cold launch (isLocked was set in init, backgroundedAt is nil), or
    ///  - the app was backgrounded for longer than the grace period.
    /// Returns immediately without prompting if the user came back quickly.
    func checkAndAuthenticateIfNeeded() async {
        guard isEnabled else { return }

        if let since = backgroundedAt {
            backgroundedAt = nil
            guard Date().timeIntervalSince(since) >= gracePeriod else {
                return  // back within 1 min — no re-auth
            }
            isLocked = true
        }

        if isLocked {
            await authenticate()
        }
    }

    func authenticate() async {
        authError = nil
        let context = LAContext()
        let reason = "Unlock AssetRack to view your financial data."
        do {
            let success: Bool = try await withCheckedThrowingContinuation { continuation in
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: success) }
                }
            }
            if success { isLocked = false }
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .systemCancel, .appCancel:
                break   // user dismissed — stay locked, no message
            default:
                authError = error.localizedDescription
            }
        } catch {
            authError = error.localizedDescription
        }
    }
}
