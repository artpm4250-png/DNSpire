import SwiftUI

@main
struct DNSpireApp: App {
    @StateObject private var configStore = ConfigStore()
    @StateObject private var tunnel = TunnelController()
    @StateObject private var logStore = LogStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(configStore)
                .environmentObject(tunnel)
                .environmentObject(logStore)
                .task {
                    tunnel.attach(logStore: logStore)
                }
        }
    }
}
