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
            switch newPhase {
            case .background:
                lockService.lockIfEnabled()
            case .active:
                // Trigger auth here — not in LockView.task — so the prompt
                // always fires after the window is fully foregrounded. Doing
                // it in LockView.task races against backgrounding: the task
                // fires while the app is still going away, LAContext gets a
                // systemCancel (swallowed silently), the task completes, and
                // nothing re-prompts when the user returns.
                if lockService.isLocked {
                    Task { await lockService.authenticate() }
                }
            default:
                break
            }
        }
        // The lock is presented in a top-level window (see LockOverlay) so it
        // covers open sheets and preserves in-progress state across lock/unlock,
        // rather than swapping the root view and tearing everything down.
        .lockOverlay(lockService)
    }
}
