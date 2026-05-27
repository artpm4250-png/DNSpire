import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            ConnectionView()
                .tabItem { Label("Connect", systemImage: "bolt.horizontal.circle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
            LogsView()
                .tabItem { Label("Logs", systemImage: "doc.text") }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(ConfigStore.preview)
        .environmentObject(ProfileStore.preview)
        .environmentObject(TunnelController())
        .environmentObject(LogStore())
        .environmentObject(VPNManager())
}
