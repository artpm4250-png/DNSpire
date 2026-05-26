// Package mobile is a gomobile-friendly facade over the MasterDnsVPN Go
// client. This file is staged into the upstream module at upstream/mobile/
// before `gomobile bind` runs — the upstream tree itself is left unmodified.
//
//	gomobile bind -target=ios -prefix DNSpire -o DNSpireCore.xcframework ./mobile
//
// The package intentionally avoids context.Context, channels, time.Duration,
// and slices of non-byte types in its public surface — gomobile cannot bind
// those.
package mobile

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"

	"masterdnsvpn-go/internal/client"
	"masterdnsvpn-go/internal/config"
)

// LogCallback is implemented on the Swift side to receive log lines from Go.
// gomobile turns single-method Go interfaces into Swift protocols.
type LogCallback interface {
	OnLog(line string)
}

// StatusCallback notifies the host about high-level state changes:
//
//	"starting", "mtu_testing", "session_init", "connected",
//	"reconnecting", "stopped", "error:<message>"
type StatusCallback interface {
	OnStatus(state string)
}

// Tunnel is a long-lived handle to a running MasterDnsVPN client instance.
// Allocate one with NewTunnel, call Start to launch the runtime, and Stop to
// tear it down. Tunnel is safe to use from multiple Swift threads.
type Tunnel struct {
	mu              sync.Mutex
	running         atomic.Bool
	cancel          context.CancelFunc
	done            chan struct{}
	app             *client.Client
	logCB           LogCallback
	statusCB        StatusCallback
	socksAddr       string
	lastStatus      string
	scratchDir      string
	resolverTmpFile string
}

// NewTunnel allocates a tunnel handle. It does not start any goroutines.
func NewTunnel() *Tunnel { return &Tunnel{} }

// SetLogCallback wires up a sink for log lines. Call before Start. The
// callback fires from a Go goroutine — Swift implementations must dispatch to
// the main queue themselves if they need to update UI.
func (t *Tunnel) SetLogCallback(cb LogCallback) {
	t.mu.Lock()
	t.logCB = cb
	t.mu.Unlock()
}

// SetStatusCallback wires up a coarse state-change sink.
func (t *Tunnel) SetStatusCallback(cb StatusCallback) {
	t.mu.Lock()
	t.statusCB = cb
	t.mu.Unlock()
}

// SocksAddress returns "host:port" of the local SOCKS5 listener once Start
// has succeeded. Empty before Start and after Stop.
func (t *Tunnel) SocksAddress() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.socksAddr
}

// IsRunning reports whether the tunnel goroutine is currently active.
func (t *Tunnel) IsRunning() bool { return t.running.Load() }

// LastStatus returns the most recent status string emitted to the callback.
func (t *Tunnel) LastStatus() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.lastStatus
}

// Start launches the upstream client using the provided JSON config blob (same
// schema as the JSON form of client_config in the upstream repo) plus a plain
// resolvers list (one entry per line, "IP" or "IP:PORT", same format as
// client_resolvers.txt). `scratchDir` is a writable directory where the
// tunnel may stage transient files (resolvers, DNS cache) — pass the app's
// NSCachesDirectory or a per-session tmp dir.
//
// The call is non-blocking: it returns once bootstrap has succeeded; MTU
// probing and session init continue in the background and surface through the
// status callback.
func (t *Tunnel) Start(configJSON string, resolversText string, scratchDir string) error {
	t.mu.Lock()
	if t.running.Load() {
		t.mu.Unlock()
		return errors.New("tunnel already running")
	}

	if scratchDir == "" {
		t.mu.Unlock()
		return errors.New("scratchDir is required")
	}
	if err := os.MkdirAll(scratchDir, 0o755); err != nil {
		t.mu.Unlock()
		return fmt.Errorf("scratchDir: %w", err)
	}

	resolverPath := ""
	if resolversText != "" {
		resolverPath = filepath.Join(scratchDir, "client_resolvers.txt")
		if err := os.WriteFile(resolverPath, []byte(resolversText), 0o644); err != nil {
			t.mu.Unlock()
			return fmt.Errorf("write resolvers: %w", err)
		}
	}

	cfg, err := loadConfigFromJSON(configJSON, resolverPath)
	if err != nil {
		t.emitStatusLocked("error:" + err.Error())
		t.mu.Unlock()
		return err
	}

	app, err := client.BootstrapLoadedConfig(cfg, "")
	if err != nil {
		t.emitStatusLocked("error:" + err.Error())
		t.mu.Unlock()
		return fmt.Errorf("bootstrap: %w", err)
	}
	t.app = app
	t.scratchDir = scratchDir
	t.resolverTmpFile = resolverPath
	t.socksAddr = fmt.Sprintf("%s:%d", cfg.ListenIP, cfg.ListenPort)

	ctx, cancel := context.WithCancel(context.Background())
	t.cancel = cancel
	t.done = make(chan struct{})
	t.running.Store(true)
	t.emitStatusLocked("starting")
	logCB := t.logCB
	socksAddr := t.socksAddr
	t.mu.Unlock()

	if logCB != nil {
		go logCB.OnLog(fmt.Sprintf("[mobile] tunnel bootstrapped; SOCKS5 will listen on %s", socksAddr))
	}

	go func() {
		defer close(t.done)
		defer t.running.Store(false)
		t.emitStatus("mtu_testing")
		if err := app.Run(ctx); err != nil {
			t.emitStatus("error:" + err.Error())
			return
		}
		t.emitStatus("stopped")
	}()

	return nil
}

// Stop cancels the tunnel and waits for the runtime goroutine to exit.
// Returns nil even if the runtime had already drained.
func (t *Tunnel) Stop() error {
	t.mu.Lock()
	cancel := t.cancel
	done := t.done
	wasRunning := t.running.Load()
	t.mu.Unlock()

	if !wasRunning && done == nil {
		return nil
	}

	if cancel != nil {
		cancel()
	}
	if done != nil {
		<-done
	}

	t.mu.Lock()
	t.cancel = nil
	t.done = nil
	t.app = nil
	t.socksAddr = ""
	t.mu.Unlock()
	t.emitStatus("stopped")
	return nil
}

func (t *Tunnel) emitStatus(state string) {
	t.mu.Lock()
	t.emitStatusLocked(state)
	t.mu.Unlock()
}

func (t *Tunnel) emitStatusLocked(state string) {
	t.lastStatus = state
	if t.statusCB != nil {
		go t.statusCB.OnStatus(state)
	}
}

func loadConfigFromJSON(configJSON string, resolversFilePath string) (config.ClientConfig, error) {
	var empty config.ClientConfig
	if configJSON == "" {
		return empty, errors.New("empty config JSON")
	}
	encoded := base64.StdEncoding.EncodeToString([]byte(configJSON))
	overrides := config.ClientConfigOverrides{Values: map[string]any{}}
	if resolversFilePath != "" {
		path := resolversFilePath
		overrides.ResolversFilePath = &path
	}
	cfg, err := config.LoadClientConfigFromJSONBase64WithOverrides(encoded, overrides)
	if err != nil {
		return empty, fmt.Errorf("parse config: %w", err)
	}
	return cfg, nil
}

// EncodeConfigBase64 is a convenience exposed to Swift: it takes a JSON config
// string and returns its base64 encoding. Useful if the host wants to embed
// the config in a file/URL/QR while keeping it compact.
func EncodeConfigBase64(configJSON string) string {
	return base64.StdEncoding.EncodeToString([]byte(configJSON))
}

// Version returns the mobile-binding version tag. Independent of the upstream
// Go client version (which it pins via go.mod).
const Version = "ios-mobile-0.1.0"
