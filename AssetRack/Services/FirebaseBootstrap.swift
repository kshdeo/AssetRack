import Foundation
import FirebaseAppCheck
import FirebaseCore

/// Starts Firebase if `GoogleService-Info.plist` is in the bundle. Without it
/// `FirebaseApp.configure()` would crash, so the app runs without Firebase
/// instead: Remote Config stays on in-app defaults and Yahoo search reports
/// itself as unavailable.
enum FirebaseBootstrap {
    private(set) static var isConfigured = false

    static func configure() {
        guard !isConfigured else { return }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            print("[FirebaseBootstrap] GoogleService-Info.plist missing — running without Firebase")
            return
        }
        // Must be set before configure().
        AppCheck.setAppCheckProviderFactory(AssetRackAppCheckProviderFactory())
        FirebaseApp.configure()
        isConfigured = true
    }
}

/// App Attest on real builds. Debug builds and the simulator can't attest, so
/// they use the debug provider, which prints a token to register in the console.
private final class AssetRackAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if DEBUG || targetEnvironment(simulator)
        return AppCheckDebugProvider(app: app)
        #else
        return AppAttestProvider(app: app)
        #endif
    }
}
