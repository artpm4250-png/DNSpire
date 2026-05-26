#!/usr/bin/env bash
# Build the iOS client locally on macOS. Mirrors what .github/workflows/ios-build.yml
# does in CI. Run from the repository root.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: iOS builds require macOS with Xcode installed." >&2
  exit 1
fi

cd "$(dirname "$0")/.."

FRAMEWORK_NAME="${FRAMEWORK_NAME:-DNSpireCore}"
MOBILE_PREFIX="${MOBILE_PREFIX:-DNSpire}"

echo "==> Checking toolchain"
command -v go >/dev/null || { echo "Go is required"; exit 1; }
command -v xcodebuild >/dev/null || { echo "Xcode command line tools are required"; exit 1; }

if ! command -v gomobile >/dev/null; then
  echo "==> Installing gomobile"
  go install golang.org/x/mobile/cmd/gomobile@latest
  go install golang.org/x/mobile/cmd/gobind@latest
  export PATH="$(go env GOPATH)/bin:$PATH"
fi

if ! command -v xcodegen >/dev/null; then
  echo "==> Installing XcodeGen via Homebrew"
  brew install xcodegen
fi

echo "==> Staging mobile-overlay into upstream/mobile"
mkdir -p upstream/mobile
cp -R mobile-overlay/. upstream/mobile/

echo "==> Fetching extra deps for PacketTunnel (gVisor + golang.org/x/net)"
# These are not in upstream's go.mod, so we add them transparently. Edits to
# upstream/go.mod and upstream/go.sum are intentionally local and not committed.
(cd upstream && \
  go get \
    gvisor.dev/gvisor@go \
    golang.org/x/net \
    golang.org/x/exp \
    golang.org/x/time \
    github.com/google/btree)

echo "==> Running gomobile init (one-time)"
(cd upstream && gomobile init >/dev/null 2>&1 || true)

echo "==> Building xcframework"
mkdir -p ios-client/Frameworks
(cd upstream && gomobile bind \
  -target=ios,iossimulator \
  -prefix "$MOBILE_PREFIX" \
  -o "../ios-client/Frameworks/${FRAMEWORK_NAME}.xcframework" \
  -trimpath \
  -ldflags="-s -w" \
  ./mobile)

echo "==> Generating Xcode project"
(cd ios-client && xcodegen generate)


echo "==> Building app for iOS Simulator"
(cd ios-client && xcodebuild \
  -project DNSpire.xcodeproj \
  -scheme DNSpire \
  -configuration Release \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build)

APP_PATH="$(find ios-client/build/Build/Products -name '*.app' -type d | head -1)"
echo
echo "==> Build succeeded."
echo "    App bundle: $APP_PATH"
echo
echo "    To run in Simulator:"
echo "      xcrun simctl boot 'iPhone 15'  # any booted device works"
echo "      xcrun simctl install booted '$APP_PATH'"
echo "      xcrun simctl launch booted com.dnspire.ios"
