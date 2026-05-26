# DNSpire — iOS client for MasterDnsVPN

A SwiftUI iOS client for [MasterDnsVPN](https://github.com/masterking32/MasterDnsVPN),
a DNS-tunneling VPN. The Go reference client is wrapped via `gomobile bind` and
embedded into a SwiftUI app that exposes its local SOCKS5 listener for external
proxy clients such as Happ or Shadowrocket.

## Status

Two operating modes, selectable in the **Connect** tab:

**1. Local SOCKS5 proxy (works with free Apple ID).** The app spawns the Go
client in-process, which opens a local SOCKS5 listener on `127.0.0.1:18000`.
Use that host and port in a third-party proxy client. No NetworkExtension
entitlement needed — sideloads cleanly with any Apple ID.

**2. System-wide VPN (requires paid Apple Developer account).** An
`NEPacketTunnelProvider` extension hosts the same Go client plus a userspace
TCP/IP stack (gVisor netstack). The extension claims the default route via
`NETunnelProviderManager`, so every TCP flow on the device is funnelled through
the DNS tunnel. UDP-53 is shimmed onto DNS-over-TCP; all other UDP is dropped
(QUIC falls back to TCP). The
`com.apple.developer.networking.networkextension` entitlement is gated to
paid-account provisioning profiles only; free Apple ID via Xcode / AltStore
**cannot** install this mode — the extension target will refuse to load.

## Layout

```
.
├── upstream/                       git submodule — clean clone of masterking32/MasterDnsVPN
├── mobile-overlay/                 Go wrapper sources. Copied into upstream/mobile/ at build time
│                                   so it can import upstream's internal/ packages without forking.
│   ├── mobile.go                   Tunnel facade — boots the MasterDnsVPN client + SOCKS5 listener
│   └── packet_tunnel.go            PacketTunnel — gVisor netstack + TCP-forwarder→SOCKS5 + DNS-over-TCP shim
├── ios-client/
│   ├── project.yml                 XcodeGen spec — the .xcodeproj is generated, not committed
│   ├── DNSpire/                    SwiftUI app sources (local proxy + VPN UI)
│   ├── DNSpirePacketTunnel/        NEPacketTunnelProvider extension (system VPN path)
│   └── Frameworks/                 gomobile output (DNSpireCore.xcframework) drops here
├── scripts/
│   └── build-local.sh              Local build on a Mac (mirrors CI)
└── .github/workflows/
    └── ios-build.yml               macos-14 runner: gomobile bind + xcodebuild
```

## Build

You have **two** paths to a working binary:

### 1. GitHub Actions (no Mac required)

Push this repo. The `Build iOS client` workflow runs on `macos-14`:

1. Installs Go 1.25, `gomobile`, `gobind`, XcodeGen.
2. `gomobile bind` produces `DNSpireCore.xcframework` from `upstream/mobile`.
3. XcodeGen generates the Xcode project from `project.yml`.
4. `xcodebuild` produces a Simulator `.app` and (best-effort) an unsigned `.ipa`.
5. Both are uploaded as the `DNSpire-ios` artifact.

Download the artifact from the Actions run. The `.app` runs directly in the
Simulator. The unsigned `.ipa` needs to be re-signed before it can install on a
real device — see "Sideloading" below.

### 2. Locally on a Mac

Prerequisites: Xcode 15+ with iOS 17 SDK, Go 1.25+, Homebrew.

```sh
./scripts/build-local.sh
```

This installs `gomobile`, `xcodegen` if missing, builds the framework, generates
the Xcode project, and produces a Simulator `.app`. Open
`ios-client/DNSpire.xcodeproj` in Xcode to run on a device with your own
signing identity.

## Sideloading on a real iPhone

The CI builds are **unsigned**. To install on a real device you need a signed
`.ipa`. Three options:

- **Free Apple ID via Xcode**: open `DNSpire.xcodeproj`, select your team
  in *Signing & Capabilities*, plug in your iPhone, hit Run. Profile expires
  after 7 days.
- **AltStore / SideStore**: drop the unsigned `.ipa` into AltStore on your Mac
  or AltStore Server; it re-signs with a free Apple ID and pushes to the device.
- **Sideloadly**: similar UX to AltStore, more permissive about the input bundle.

## Server side

This client expects a running [MasterDnsVPN server](https://github.com/masterking32/MasterDnsVPN#server-setup).
You need:

1. A domain you control (e.g. `example.com`).
2. A VPS with a public IPv4.
3. Delegate a subdomain (e.g. `v.example.com`) to the VPS by adding an `A`
   record for the VPS IP plus an `NS` record pointing the subdomain at it.
4. Run `server_linux_install.sh` from the upstream repo on the VPS.

The values you need to copy into the iOS app's **Settings** tab:

| Server field           | iOS app field           |
|------------------------|-------------------------|
| `DOMAINS`              | Domains                 |
| `encrypt_key.txt`      | Encryption key          |
| `DATA_ENCRYPTION_METHOD` | Encryption method     |

The resolvers list is what the client uses to reach the server; it does not
need to match anything on the server side. In the iOS app, open **Settings →
Resolvers** and paste one resolver per line or a comma-separated list.

## How local proxy mode works

The Go client opens a SOCKS5 server on `127.0.0.1:18000` (configurable). The
Swift side starts and stops that Go client, then shows the host and port for
external proxy clients. Configure Happ, Shadowrocket, or a similar app to use
`127.0.0.1` and port `18000` as a SOCKS5 proxy.

This **only** affects apps that explicitly use the local SOCKS5 proxy. The rest
of the system continues to use the device's normal network path. That's the
trade-off versus a Packet Tunnel: simpler distribution, narrower scope.

## How system-wide VPN works

The `DNSpirePacketTunnel` extension hosts:

1. The MasterDnsVPN Go client (same one local proxy mode uses) — opens a
   loopback SOCKS5 listener on `127.0.0.1:18000` inside the extension process.
2. A gVisor `stack.Stack` with a `channel.Endpoint` that bridges to
   `NEPacketTunnelFlow`. Swift reads packets from iOS, calls
   `pt.writePacket(...)`; Go pushes outbound packets back via a
   `PacketCallback` Swift implements (writes to `packetFlow.writePacketObjects`).
3. A `tcp.Forwarder` on the gVisor stack: every inbound TCP SYN gets a
   `CreateEndpoint` accept, then we `dialer.Dial("tcp", origDest)` through the
   loopback SOCKS5. Two goroutines pipe bytes both ways.
4. A UDP-53 interceptor at the link-endpoint level: DNS queries are unwrapped
   from their UDP envelope, sent as DNS-over-TCP through SOCKS5 to a public
   resolver, and the response is re-wrapped as a UDP IP packet back to the
   originating address. All other UDP is silently dropped.

### Constraints

- **Paid Apple Developer account required.** The
  `com.apple.developer.networking.networkextension` entitlement is **not**
  included in free provisioning profiles. The app will build and install
  unsigned, but iOS will silently refuse to load the extension when you toggle
  "System VPN" in the UI.
- **50 MB extension memory limit.** gVisor's netstack is the heaviest tenant.
  The current configuration uses 512 packet buffers in `channel.New` and the
  default `tcp.Forwarder` (1024 max in-flight). Watch
  `proc_info_extended.phys_footprint` if memory becomes a concern.
- **TCP-only data plane.** Non-DNS UDP is dropped. Most modern apps (Safari,
  Chrome, native iOS networking) fall back to TCP if UDP/QUIC stalls — voice,
  some games, and pure-UDP protocols won't work.
- **No IPv6.** The tunnel advertises IPv4-only network settings because the
  upstream MasterDnsVPN channel is IPv4-only.

## License

Wrapper code in this repo is MIT. The vendored `upstream/` tree is unmodified
MasterDnsVPN, MIT-licensed, copyright MasterkinG32. See `upstream/LICENSE`.
