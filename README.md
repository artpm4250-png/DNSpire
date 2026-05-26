# DNSpire — iOS client for MasterDnsVPN

A SwiftUI iOS client for [MasterDnsVPN](https://github.com/masterking32/MasterDnsVPN),
a DNS-tunneling VPN. The Go reference client is wrapped via `gomobile bind` and
embedded into a SwiftUI app that exposes its local SOCKS5 listener through an
in-app `WKWebView` browser.

## Status

**v1 — in-app browser only.** The app spawns the Go client in-process, which
opens a local SOCKS5 listener on `127.0.0.1:18000`. The built-in **Browser** tab
routes WebKit traffic through that SOCKS5 (via `WKWebsiteDataStore.proxyConfigurations`,
iOS 17+). No `NEPacketTunnelProvider` extension, no `NetworkExtension`
entitlement — sideloads cleanly with any Apple ID.

**v2 (not implemented)** would add a Packet Tunnel extension with an in-process
TCP/IP stack (tun2socks) so the whole system routes through the tunnel. That
requires the NetworkExtension entitlement and a `gVisor`-based stack — left for
a follow-up.

## Layout

```
.
├── upstream/                   git submodule — clean clone of masterking32/MasterDnsVPN
├── mobile-overlay/             Go wrapper sources. Copied into upstream/mobile/ at build time
│                               so it can import upstream's internal/ packages without forking.
├── ios-client/
│   ├── project.yml             XcodeGen spec — the .xcodeproj is generated, not committed
│   ├── DNSpire/                SwiftUI sources
│   └── Frameworks/             gomobile output (DNSpireCore.xcframework) drops here
├── scripts/
│   └── build-local.sh          Local build on a Mac (mirrors CI)
└── .github/workflows/
    └── ios-build.yml           macos-14 runner: gomobile bind + xcodebuild
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

The resolvers list (Cloudflare/Google/Quad9 entries pre-populated) is what the
client uses to reach the server; it does not need to match anything on the
server side.

## How the in-app browser works

The Go client opens a SOCKS5 server on `127.0.0.1:18000` (configurable). The
Swift side creates a `WKWebView` whose `WKWebsiteDataStore` is configured with
a `ProxyConfiguration(socksv5Proxy:)` pointing at that endpoint. WebKit on iOS
17+ honours per-data-store proxy settings, so all traffic from that web view
flows through the DNS tunnel.

This **only** affects the in-app browser. The rest of the system continues to
use the device's normal network path. That's the trade-off versus a Packet
Tunnel: simpler distribution, narrower scope.

## Adding system-wide VPN (v2 roadmap)

To route all device traffic through the tunnel you need:

1. A `NEPacketTunnelProvider` app extension with the `com.apple.developer.networking.networkextension`
   entitlement (paid Developer account required; Apple reviews VPN apps closely).
2. A `tun2socks` layer that consumes IP packets from `NEPacketTunnelFlow.readPackets`,
   reconstructs TCP flows, hands them to the local SOCKS5, and writes responses
   back as IP packets. `xjasonlyu/tun2socks/v2` is a good gVisor-based starting
   point and can be embedded into the same `gomobile bind` package.
3. Careful memory budgeting — Packet Tunnel extensions have a 50 MB hard limit.

None of this is wired up in v1.

## License

Wrapper code in this repo is MIT. The vendored `upstream/` tree is unmodified
MasterDnsVPN, MIT-licensed, copyright MasterkinG32. See `upstream/LICENSE`.
