import SwiftUI

@main
struct DNSpireApp: App {
    @StateObject private var configStore = ConfigStore()
    @StateObject private var profileStore = ProfileStore()
    @StateObject private var tunnel = TunnelController()
    @StateObject private var logStore = LogStore()
    @StateObject private var vpn = VPNManager()
    @StateObject private var testRunner = ServerTestRunner()
    @StateObject private var mtuHints = MTUHintStore()

    @State private var importAlert: ImportAlert?

    private struct ImportAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(configStore)
                .environmentObject(profileStore)
                .environmentObject(tunnel)
                .environmentObject(logStore)
                .environmentObject(vpn)
                .environmentObject(testRunner)
                .environmentObject(mtuHints)
                .task {
                    tunnel.attach(logStore: logStore)
                    vpn.attach(logStore: logStore)
                    vpn.attach(mtuHintStore: mtuHints)
                    let knownIDs = Set(profileStore.servers.map(\.id))
                    testRunner.prune(to: knownIDs)
                    mtuHints.prune(to: knownIDs)
                }
                .onOpenURL { url in
                    handleIncoming(url)
                }
                .alert(item: $importAlert) { alert in
                    Alert(title: Text(alert.title),
                          message: Text(alert.message),
                          dismissButton: .default(Text("OK")))
                }
        }
    }

    private func handleIncoming(_ url: URL) {
        do {
            let imported = try StormDNSProfileLink.decode(url.absoluteString)
            var draft = ClientConfigDraft.default
            draft.domains = [imported.domain]
            draft.encryptionKey = imported.encryptionKey
            draft.dataEncryptionMethod = imported.encryptionMethod
            profileStore.captureServerAsNew(from: draft, name: imported.name)
            importAlert = ImportAlert(
                title: "Profile imported",
                message: "Added server profile “\(imported.name)”. Open the Server list to switch to it."
            )
        } catch {
            let reason = (error as? StormDNSProfileLink.DecodeError)?.errorDescription
                ?? error.localizedDescription
            importAlert = ImportAlert(title: "Import failed", message: reason)
        }
    }
}
