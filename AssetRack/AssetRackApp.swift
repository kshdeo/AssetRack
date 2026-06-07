import SwiftUI
import SwiftData

@main
struct AssetRackApp: App {
    let container: ModelContainer
    let lockService = BiometricLockService()

    init() {
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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(lockService)
        }
        .modelContainer(container)
    }
}
