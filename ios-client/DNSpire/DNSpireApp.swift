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
    @StateObject private var scanner = ResolverScanner()

    /// User-controlled opt-in. When true, on app launch DNSpire compares the
    /// active server profile against persisted [[ServerTestRunner]] results
    /// and silently switches to the fastest `.ok` candidate (provided no
    /// tunnel is active). Default off because changing the active server is
    /// a user choice we shouldn't override without consent.
    @AppStorage("DNSpire.autoPickFastestEnabled") private var autoPickEnabled: Bool = false

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
                .environmentObject(scanner)
                .task {
                    tunnel.attach(logStore: logStore)
                    vpn.attach(logStore: logStore)
                    vpn.attach(mtuHintStore: mtuHints)
                    let knownIDs = Set(profileStore.servers.map(\.id))
                    testRunner.prune(to: knownIDs)
                    mtuHints.prune(to: knownIDs)
                    if autoPickEnabled {
                        await applyAutoPickIfIdle()
                    }
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

    /// Switch `activeServerID` to the lowest-latency `.ok` candidate from
    /// `testRunner.results` — but only if no tunnel is up. `vpn.reloadManager`
    /// is awaited so the NETunnelProviderManager status is settled before we
    /// decide; otherwise an in-flight `.connecting` would look identical to
    /// `.disconnected`. Refuses to switch when the user has only one server
    /// or when the current active is already fastest.
    @MainActor
    private func applyAutoPickIfIdle() async {
        await vpn.reloadManager()
        let busy = vpn.status == .connected
            || vpn.status == .connecting
            || vpn.status == .reasserting
        guard !busy else { return }
        guard tunnel.status == .stopped else { return }
        guard profileStore.servers.count >= 2 else { return }
        let candidates = profileStore.servers.map(\.id)
        guard let best = testRunner.fastestServerID(among: candidates) else { return }
        guard best.id != profileStore.activeServerID else { return }
        let name = profileStore.servers.first { $0.id == best.id }?.name ?? "?"
        profileStore.setActiveServer(best.id, applying: &configStore.draft)
        logStore.append("[auto] picked fastest server '\(name)' (\(best.ms) ms)")
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
