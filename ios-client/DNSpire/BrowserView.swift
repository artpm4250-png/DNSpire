import SwiftUI
import WebKit
import Network

struct BrowserView: View {
    @EnvironmentObject var tunnel: TunnelController
    @State private var urlString: String = "https://check.torproject.org"
    @State private var loadTrigger: Int = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("https://…", text: $urlString)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onSubmit { loadTrigger += 1 }
                    Button("Go") { loadTrigger += 1 }
                        .buttonStyle(.borderedProminent)
                }
                .padding(8)
                Divider()

                if tunnel.socksAddress.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "network.slash").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Tunnel not connected").font(.headline)
                        Text("Open the Connect tab and start the tunnel to browse through DNSpire.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SOCKSWebView(
                        urlString: urlString,
                        socksAddress: tunnel.socksAddress,
                        loadTrigger: loadTrigger
                    )
                }
            }
            .navigationTitle("Browser")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Wraps WKWebView with a per-instance WKWebsiteDataStore that routes traffic
/// through the local Go SOCKS5 listener. Requires iOS 17+.
private struct SOCKSWebView: UIViewRepresentable {
    let urlString: String
    let socksAddress: String
    let loadTrigger: Int

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = makeDataStore()
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Reconfigure proxy if the SOCKS address changed between renders.
        if let store = makeDataStore() as WKWebsiteDataStore?, store !== uiView.configuration.websiteDataStore {
            uiView.configuration.websiteDataStore = store
        }
        guard let url = sanitizedURL else { return }
        if uiView.url != url || context.coordinator.lastTrigger != loadTrigger {
            context.coordinator.lastTrigger = loadTrigger
            uiView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastTrigger: Int = -1
    }

    private var sanitizedURL: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            return URL(string: trimmed)
        }
        return URL(string: "https://" + trimmed)
    }

    /// Build a fresh non-persistent data store whose ProxyConfiguration points
    /// at the Go-side SOCKS5 listener. iOS 17+ exposes proxy settings on
    /// WKWebsiteDataStore directly; earlier versions cannot do this.
    private func makeDataStore() -> WKWebsiteDataStore {
        let parts = socksAddress.split(separator: ":", maxSplits: 1)
        let host = String(parts.first ?? "127.0.0.1")
        let port = parts.count > 1 ? UInt16(parts[1]) ?? 18000 : 18000
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port)
        )
        let proxy = ProxyConfiguration(socksv5Proxy: endpoint)
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [proxy]
        return store
    }
}
