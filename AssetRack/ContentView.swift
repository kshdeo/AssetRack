import SwiftUI

struct ContentView: View {
    /// Persisted across launches. Flipped to `true` when the user finishes (or
    /// skips) onboarding; the flow never appears again until the app is
    /// reinstalled.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding {
            DashboardView()
        } else {
            OnboardingView(isCompleted: $hasCompletedOnboarding)
                .transition(.opacity)
        }
    }
}
