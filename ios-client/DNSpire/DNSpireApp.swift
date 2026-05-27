import SwiftUI

@main
struct DNSpireApp: App {
    @StateObject private var configStore = ConfigStore()
    @StateObject private var profileStore = ProfileStore()
    @StateObject private var tunnel = TunnelController()
    @StateObject private var logStore = LogStore()
    @StateObject private var vpn = VPNManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(configStore)
                .environmentObject(profileStore)
                .environmentObject(tunnel)
                .environmentObject(logStore)
                .environmentObject(vpn)
                .task {
                    tunnel.attach(logStore: logStore)
                    vpn.attach(logStore: logStore)
                }
        }
    }
}
