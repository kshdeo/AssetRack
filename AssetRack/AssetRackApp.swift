import SwiftUI
import SwiftData

@main
struct AssetRackApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(ModelContainer.appContainer)
    }
}
