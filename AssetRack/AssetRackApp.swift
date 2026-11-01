import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct AssetRackApp: App {
    let container: ModelContainer
    let lockService = BiometricLockService()
    let demoMode = DemoMode()

    init() {
        FirebaseBootstrap.configure()
        let schema = Schema([Account.self, Holding.self, BalanceSnapshot.self, NetWorthSnapshot.self, ProjectionSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Schema mismatch from model changes during development — wipe and retry.
            // Replace with a proper migration plan before App Store submission.
            print("[AssetRackApp] Store incompatible, wiping and retrying: \(error)")
            let storeURL = config.url
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("shm"))
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("wal"))
            do {
                container = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Could not create ModelContainer even after wiping store: \(error)")
            }
        }
        BackgroundRefreshService.registerHandler(container: container)
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(container: container)
                .environment(lockService)
                .environment(demoMode)
                .onAppear {
                    BackgroundRefreshService.scheduleNext()
                }
                .task {
                    await ConfigService.shared.fetchAndActivate()
                }
        }
    }
}

/// Points the whole view tree at the real store or the demo session's in-memory
/// one. The `.id` rebuilds the tree on a swap so view-owned services
/// (`CurrencyService`, `TickerService`) are recreated for the right mode.
private struct AppRootView: View {
    let container: ModelContainer
    @Environment(DemoMode.self) private var demoMode

    var body: some View {
        ContentView()
            .id(demoMode.isActive)
            .modelContainer(demoMode.container ?? container)
    }
}
