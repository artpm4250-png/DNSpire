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
	"bufio"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

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
	// Captured in Start when we redirect os.Stdout / os.Stderr through pipes
	// so the upstream `logger.Logger` (which writes to os.Stdout, frozen at
	// constructor time) ends up streaming into the host's LogCallback.
	// Restored and closed in Stop so the next Start can re-hook fresh pipes
	// and the GC can reclaim everything.
	stdoutPipeR *os.File
	stdoutPipeW *os.File
	stderrPipeR *os.File
	stderrPipeW *os.File
	prevStdout  *os.File
	prevStderr  *os.File
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

	// Hijack os.Stdout / os.Stderr BEFORE BootstrapLoadedConfig so the upstream
	// logger.Logger (constructed inside Bootstrap) freezes our pipe's write end
	// as its console writer. iOS swallows stdout/stderr for sandboxed apps, so
	// without this the only logs reaching the UI would be the [ui]/[vpn]/
	// [mobile] lines we synthesize on our side — the actual client narration
	// (MTU probes, session init, resolver rotation, errors) would be invisible.
	// On failure to set up pipes we degrade gracefully: bootstrap still
	// proceeds, just without client-side logs in the UI.
	currentCB := t.logCB
	if currentCB != nil {
		t.installStdioCapture(currentCB)
	}

	app, err := client.BootstrapLoadedConfig(cfg, "")
	if err != nil {
		t.restoreStdioCapture()
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

	t.emitStatus("mtu_testing")

	go func() {
		defer close(t.done)
		defer t.running.Store(false)
		if err := app.Run(ctx); err != nil {
			t.emitStatus("error:" + err.Error())
			return
		}
		t.emitStatus("stopped")
	}()

	go t.watchRuntimeStatus(ctx, app, socksAddr)

	return nil
}

// watchRuntimeStatus polls the upstream client until ctx is cancelled, emitting
// status transitions the UI relies on. Without it, mobile.go would only ever
// report "mtu_testing" and "stopped" — the upstream Run loop never calls back.
//
// State derivation (from outside the package, with only SessionReady exported):
//   - SessionReady=false                     → mtu_testing (MTU probing or
//                                              session-init failures retry)
//   - SessionReady=true, listener refusing   → session_init (narrow window
//                                              between session ready and
//                                              StartAsyncRuntime opening port)
//   - SessionReady=true, listener accepting  → connected
//
// Once connected, we keep watching: if SessionReady drops back to false we
// report "reconnecting" so the UI reflects mid-session resets.
func (t *Tunnel) watchRuntimeStatus(ctx context.Context, app *client.Client, socksAddr string) {
	probeAddr := normalizeProbeAddress(socksAddr)
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	last := "mtu_testing"
	reachedConnected := false

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			next := last
			ready := app.SessionReady()
			switch {
			case !ready && reachedConnected:
				next = "reconnecting"
			case !ready:
				next = "mtu_testing"
			case ready && !probeListener(probeAddr):
				next = "session_init"
			default:
				next = "connected"
				reachedConnected = true
			}
			if next != last {
				t.emitStatus(next)
				last = next
			}
		}
	}
}

// normalizeProbeAddress maps a wildcard listen address ("0.0.0.0", "::",
// or empty host) to a loopback target the in-process prober can actually
// dial. Anything else is returned as-is.
func normalizeProbeAddress(socksAddr string) string {
	host, port, err := net.SplitHostPort(socksAddr)
	if err != nil {
		return socksAddr
	}
	switch host {
	case "", "0.0.0.0":
		host = "127.0.0.1"
	case "::":
		host = "::1"
	}
	return net.JoinHostPort(host, port)
}

// probeListener returns true if a TCP connection succeeds within a short
// budget. We don't speak SOCKS5 here — accept is enough to know the upstream
// runtime has reached StartAsyncRuntime and bound the listener.
func probeListener(addr string) bool {
	conn, err := net.DialTimeout("tcp", addr, 200*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
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
	t.restoreStdioCapture()
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

// installStdioCapture redirects os.Stdout and os.Stderr through pipes that a
// pair of goroutines drain line-by-line, forwarding each line to cb tagged as
// `[client]`. Must be called with t.mu held. Idempotent in the sense that a
// subsequent call without an intervening restore replaces the previous pipes
// (the old ones are closed, their drain goroutines exit on EOF).
func (t *Tunnel) installStdioCapture(cb LogCallback) {
	// Tear down any leftover pipes from a previous Start that didn't go
	// through Stop (shouldn't happen, but be defensive).
	t.restoreStdioCapture()

	outR, outW, err := os.Pipe()
	if err != nil {
		return
	}
	errR, errW, pipeErr := os.Pipe()
	if pipeErr != nil {
		_ = outR.Close()
		_ = outW.Close()
		return
	}

	t.prevStdout = os.Stdout
	t.prevStderr = os.Stderr
	t.stdoutPipeR = outR
	t.stdoutPipeW = outW
	t.stderrPipeR = errR
	t.stderrPipeW = errW

	os.Stdout = outW
	os.Stderr = errW

	go drainPipe(outR, cb)
	go drainPipe(errR, cb)
}

// restoreStdioCapture reverses installStdioCapture. Safe to call when no
// capture is active (no-op). Must be called with t.mu held.
func (t *Tunnel) restoreStdioCapture() {
	if t.prevStdout != nil {
		os.Stdout = t.prevStdout
		t.prevStdout = nil
	}
	if t.prevStderr != nil {
		os.Stderr = t.prevStderr
		t.prevStderr = nil
	}
	// Closing the write ends causes the drain goroutines reading the
	// corresponding read ends to see EOF and exit. The read ends are also
	// closed (defensive — drain goroutines also close on exit) so file
	// descriptors are released promptly.
	if t.stdoutPipeW != nil {
		_ = t.stdoutPipeW.Close()
		t.stdoutPipeW = nil
	}
	if t.stderrPipeW != nil {
		_ = t.stderrPipeW.Close()
		t.stderrPipeW = nil
	}
	t.stdoutPipeR = nil
	t.stderrPipeR = nil
}

// drainPipe reads lines from r until EOF, forwarding each as a `[client]`
// log event. ANSI escape sequences from the upstream logger's colored output
// are stripped — the iOS UI renders colours from its own level detection
// pass, and raw escape codes would look like noise.
func drainPipe(r *os.File, cb LogCallback) {
	defer r.Close()
	scanner := bufio.NewScanner(r)
	// Allow long lines: the upstream MTU table dumps can run beyond the
	// default 64KiB scanner limit when many resolvers are listed.
	const maxLine = 1 << 20
	scanner.Buffer(make([]byte, 0, 4096), maxLine)
	for scanner.Scan() {
		line := stripANSI(scanner.Text())
		if line == "" {
			continue
		}
		// gomobile callbacks block the calling goroutine until Swift returns.
		// Dispatch each line on its own goroutine so a slow Swift handler
		// can't back-pressure the upstream logger (which holds an internal
		// mutex while writing).
		go cb.OnLog("[client] " + line)
	}
}

// stripANSI removes CSI / SGR escape sequences (the `\x1b[…m` style colour
// codes the upstream logger emits) so they don't show up as `^[[31m...` in
// the UI.
func stripANSI(s string) string {
	if !containsByte(s, 0x1b) {
		return s
	}
	out := make([]byte, 0, len(s))
	i := 0
	for i < len(s) {
		c := s[i]
		if c != 0x1b {
			out = append(out, c)
			i++
			continue
		}
		// ESC [ ... letter — skip until the terminator (a letter A-Za-z).
		if i+1 < len(s) && s[i+1] == '[' {
			j := i + 2
			for j < len(s) {
				b := s[j]
				j++
				if (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') {
					break
				}
			}
			i = j
			continue
		}
		// Stray ESC with no '[' — drop just the ESC and continue.
		i++
	}
	return string(out)
}

func containsByte(s string, b byte) bool {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return true
		}
	}
	return false
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

// ProbeServer runs a one-shot handshake against the server described by
// configJSON + resolversText: BootstrapLoadedConfig → RunInitialMTUTests →
// InitializeSession, all under a single ctx-with-timeout, then tears down.
//
// Unlike Tunnel.Start, the probe:
//   - never opens the SOCKS5 listener (does not call StartAsyncRuntime),
//   - never hijacks os.Stdout / os.Stderr (so it co-exists with a live tunnel
//     whose log pipe is currently installed),
//   - never spawns any goroutine that outlives the call.
//
// On success returns the elapsed wall-clock time from start to "session
// ready" in milliseconds. On failure returns 0 and an error whose
// Error() string is prefixed with a category — "timeout", "mtu",
// "handshake", "config:..." — so Swift can render it without parsing
// free-form text. scratchDir is wiped on return.
func ProbeServer(configJSON, resolversText, scratchDir string, timeoutMs int) (int64, error) {
	if scratchDir == "" {
		return 0, errors.New("config:scratchDir is required")
	}
	if err := os.MkdirAll(scratchDir, 0o755); err != nil {
		return 0, fmt.Errorf("config:scratchDir: %w", err)
	}
	defer os.RemoveAll(scratchDir)

	resolverPath := ""
	if resolversText != "" {
		resolverPath = filepath.Join(scratchDir, "client_resolvers.txt")
		if err := os.WriteFile(resolverPath, []byte(resolversText), 0o644); err != nil {
			return 0, fmt.Errorf("config:write resolvers: %w", err)
		}
	}

	cfg, err := loadConfigFromJSON(configJSON, resolverPath)
	if err != nil {
		return 0, fmt.Errorf("config:%s", err.Error())
	}
	// Force-quiet the probe logger so it doesn't pollute the (stdout-capturing)
	// log pipe of a tunnel that might be running concurrently. Errors still
	// surface via the returned error.
	cfg.LogLevel = "ERROR"

	if timeoutMs <= 0 {
		timeoutMs = 20_000
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()

	start := time.Now()

	app, err := client.BootstrapLoadedConfig(cfg, "")
	if err != nil {
		return 0, fmt.Errorf("config:%s", err.Error())
	}

	if err := app.RunInitialMTUTests(ctx); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return 0, errors.New("timeout")
		}
		if errors.Is(err, client.ErrNoValidConnections) {
			return 0, errors.New("mtu")
		}
		return 0, fmt.Errorf("mtu:%s", err.Error())
	}
	// RunInitialMTUTests honours ctx by returning nil on cancel — re-check.
	if ctx.Err() == context.DeadlineExceeded {
		return 0, errors.New("timeout")
	}

	if err := app.InitializeSession(1); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return 0, errors.New("timeout")
		}
		if errors.Is(err, client.ErrNoValidConnections) {
			return 0, errors.New("mtu")
		}
		return 0, errors.New("handshake")
	}

	return time.Since(start).Milliseconds(), nil
}

// Version returns the mobile-binding version tag. Independent of the upstream
// Go client version (which it pins via go.mod).
const Version = "ios-mobile-0.1.0"
