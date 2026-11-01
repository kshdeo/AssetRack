import SwiftUI

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(BiometricLockService.self) private var lockService
    @Environment(DemoMode.self) private var demoMode
    @Environment(\.scenePhase) private var scenePhase
    @State private var dismissedUpdatePrompt = false

    var body: some View {
        Group {
            // Demo mode doesn't touch the onboarding flag: exiting returns to
            // wherever the user was, including onboarding if they never finished.
            if hasCompletedOnboarding || demoMode.isActive {
                DashboardView()
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if demoMode.isActive {
                            DemoBanner(onExit: demoMode.exit)
                        }
                    }
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

/// Always-visible reminder that the numbers on screen are sample data.
private struct DemoBanner: View {
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)
            Text("Demo mode: sample data")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button("Exit", action: onExit)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Exit demo mode")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }
}
