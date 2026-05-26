import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            ConnectionView()
                .tabItem { Label("Connect", systemImage: "bolt.horizontal.circle") }
            BrowserView()
                .tabItem { Label("Browser", systemImage: "safari") }
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
        .environmentObject(TunnelController())
        .environmentObject(LogStore())
}
