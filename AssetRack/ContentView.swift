import SwiftUI

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(BiometricLockService.self) private var lockService
    @Environment(\.scenePhase) private var scenePhase
    @State private var dismissedUpdatePrompt = false

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                DashboardView()
            } else {
                OnboardingView(isCompleted: $hasCompletedOnboarding)
                    .transition(.opacity)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                lockService.noteBackground()
            case .active:
                Task { await lockService.checkAndAuthenticateIfNeeded() }
            default:
                break
            }
        }
        // The lock is presented in a top-level window (see LockOverlay) so it
        // covers open sheets and preserves in-progress state across lock/unlock,
        // rather than swapping the root view and tearing everything down.
        .lockOverlay(lockService)
        // Dismissible on purpose: a bad remote value must never lock anyone out
        // of their own data.
        .alert("Update Recommended", isPresented: Binding(
            get: { ConfigService.shared.isUpdateRequired && !dismissedUpdatePrompt },
            set: { if !$0 { dismissedUpdatePrompt = true } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This version of Assets Rack is no longer supported. Please update from the App Store.")
        }
    }
}
