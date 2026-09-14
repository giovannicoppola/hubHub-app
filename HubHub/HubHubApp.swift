import SwiftUI

@main
struct HubHubApp: App {
    @StateObject private var store = StatsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
