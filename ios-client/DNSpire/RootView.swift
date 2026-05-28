import SwiftUI

/// Single-screen root. The previous 4-tab `TabView` (Connect / Scan /
/// Settings / Logs) collapsed into [[HomeView]] — Connect is the home;
/// Scan / Logs / App preferences / Import live behind HomeView's toolbar
/// sheets. Per-profile config (the bulk of what was on the Settings tab)
/// is reached through [[ProfileEditSheets]] off the profile selector card.
struct RootView: View {
    var body: some View {
        HomeView()
    }
}

#Preview {
    RootView()
        .environmentObject(ConfigStore.preview)
        .environmentObject(ProfileStore.preview)
        .environmentObject(TunnelController())
        .environmentObject(LogStore())
        .environmentObject(VPNManager())
        .environmentObject(ServerTestRunner())
        .environmentObject(MTUHintStore())
        .environmentObject(ResolverScanner())
}
