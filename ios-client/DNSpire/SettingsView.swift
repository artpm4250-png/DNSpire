import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var configStore: ConfigStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Tunnel Identity") {
                    DomainsEditor(domains: $configStore.draft.domains)
                    SecureField("Encryption key", text: $configStore.draft.encryptionKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Picker("Encryption method", selection: $configStore.draft.dataEncryptionMethod) {
                        Text("None").tag(0)
                        Text("XOR").tag(1)
                        Text("ChaCha20").tag(2)
                        Text("AES-128-GCM").tag(3)
                        Text("AES-192-GCM").tag(4)
                        Text("AES-256-GCM").tag(5)
                    }
                }

                Section("Local Proxy") {
                    Picker("Mode", selection: $configStore.draft.protocolType) {
                        Text("SOCKS5").tag("SOCKS5")
                        Text("TCP").tag("TCP")
                    }
                    LabeledContent("Listen IP") {
                        TextField("127.0.0.1", text: $configStore.draft.listenIP)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    LabeledContent("Listen port") {
                        TextField("18000", value: $configStore.draft.listenPort, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("Require SOCKS5 auth", isOn: $configStore.draft.socks5AuthEnabled)
                    if configStore.draft.socks5AuthEnabled {
                        LabeledContent("User") {
                            TextField("user", text: $configStore.draft.socks5User)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        LabeledContent("Password") {
                            SecureField("password", text: $configStore.draft.socks5Pass)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section("Resolvers") {
                    ResolverEditor(resolvers: $configStore.draft.resolvers)
                }

                Section("Logging") {
                    Picker("Log level", selection: $configStore.draft.logLevel) {
                        Text("DEBUG").tag("DEBUG")
                        Text("INFO").tag("INFO")
                        Text("WARN").tag("WARN")
                        Text("ERROR").tag("ERROR")
                    }
                }

                Section {
                    Button("Reset to defaults", role: .destructive) {
                        configStore.draft = .default
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct DomainsEditor: View {
    @Binding var domains: [String]

    var body: some View {
        ForEach(Array(domains.enumerated()), id: \.offset) { idx, _ in
            HStack {
                TextField("v.example.com", text: $domains[idx])
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                if domains.count > 1 {
                    Button(role: .destructive) {
                        domains.remove(at: idx)
                    } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless)
                }
            }
        }
        Button {
            domains.append("")
        } label: {
            Label("Add domain", systemImage: "plus.circle")
        }
    }
}

private struct ResolverEditor: View {
    @Binding var resolvers: [ResolverEntry]

    var body: some View {
        ForEach(Array(resolvers.enumerated()), id: \.element.id) { idx, _ in
            HStack(spacing: 8) {
                Toggle("", isOn: $resolvers[idx].enabled).labelsHidden()
                TextField("IP", text: $resolvers[idx].ip)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                TextField("Port", value: $resolvers[idx].port, format: .number)
                    .keyboardType(.numberPad)
                    .frame(width: 60)
                Button(role: .destructive) {
                    resolvers.remove(at: idx)
                } label: { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.borderless)
            }
        }
        Button {
            resolvers.append(.init(ip: "", port: 53, enabled: true))
        } label: {
            Label("Add resolver", systemImage: "plus.circle")
        }
    }
}
