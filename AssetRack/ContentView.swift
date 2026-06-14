import SwiftUI

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(BiometricLockService.self) private var lockService
    @Environment(\.scenePhase) private var scenePhase

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
            if newPhase == .background {
                lockService.lockIfEnabled()
            }
        }
        // The lock is presented in a top-level window (see LockOverlay) so it
        // covers open sheets and preserves in-progress state across lock/unlock,
        // rather than swapping the root view and tearing everything down.
        .lockOverlay(lockService)
    }
}
