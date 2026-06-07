import SwiftUI

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(BiometricLockService.self) private var lockService
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if lockService.isLocked {
                LockView()
            } else if hasCompletedOnboarding {
                DashboardView()
            } else {
                OnboardingView(isCompleted: $hasCompletedOnboarding)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: lockService.isLocked)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                lockService.lockIfEnabled()
            }
        }
    }
}
