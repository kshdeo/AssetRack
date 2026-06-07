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

    init() {
        refreshCapabilities()
        if isEnabled { isLocked = true }
    }

    // Re-check at call sites where the enrolment state may have changed
    // (e.g. when the user returns from Settings.app).
    func refreshCapabilities() {
        let context = LAContext()
        var error: NSError?
        canUseLock = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        // biometryType is populated as a side-effect of canEvaluatePolicy above.
        biometryType = context.biometryType
    }

    func lockIfEnabled() {
        guard isEnabled else { return }
        isLocked = true
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
