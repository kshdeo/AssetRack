import SwiftUI
import UIKit

// MARK: - Lock overlay window
//
// The biometric lock must cover *everything* — including any `.sheet` the user
// has open (e.g. the Add Account form). A SwiftUI overlay placed inside
// `ContentView` can't do that: a sheet is presented above ContentView, so an
// in-hierarchy overlay would sit *behind* it, and swapping ContentView's root
// to a lock screen tears the sheet (and all its in-progress state) down.
//
// Instead we present the lock screen in a separate `UIWindow` at `.alert`
// level. It floats above the app's main window and any modal sheets, while the
// underlying view hierarchy stays mounted untouched. Unlocking just removes the
// window, revealing the app exactly where the user left it.

@MainActor
final class LockWindowManager {
    private var window: UIWindow?

    func update(isLocked: Bool, service: BiometricLockService) {
        isLocked ? show(service: service) : hide()
    }

    private func show(service: BiometricLockService) {
        guard window == nil, let scene = activeScene else { return }
        let host = UIHostingController(rootView: LockView().environment(service))
        host.view.backgroundColor = .systemBackground

        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1     // above the main window and any sheets
        w.rootViewController = host
        w.makeKeyAndVisible()
        window = w
    }

    private func hide() {
        window?.isHidden = true
        window = nil   // releases the window and its hosting controller
    }

    private var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

// MARK: - View modifier

private struct LockOverlayModifier: ViewModifier {
    let service: BiometricLockService
    @State private var manager = LockWindowManager()

    func body(content: Content) -> some View {
        content
            // Show on first appearance if we launched into a locked state…
            .onAppear { manager.update(isLocked: service.isLocked, service: service) }
            // …and react to every lock/unlock thereafter. Reading
            // `service.isLocked` here registers the @Observable dependency.
            .onChange(of: service.isLocked) { _, locked in
                manager.update(isLocked: locked, service: service)
            }
    }
}

extension View {
    /// Presents the biometric lock screen in a top-level window whenever
    /// `service.isLocked` is true, leaving the underlying UI (and any open
    /// sheets) intact.
    func lockOverlay(_ service: BiometricLockService) -> some View {
        modifier(LockOverlayModifier(service: service))
    }
}
