// PacketTunnel — userspace TCP/IP stack on top of the existing MasterDnsVPN
// SOCKS5 client, designed to be driven from an NEPacketTunnelProvider.
//
// Architecture:
//   NEPacketTunnelFlow ──(Swift WritePacket)──▶ gVisor netstack ──▶ SOCKS5 dialer
//                                                                       ▲
//                              MasterDnsVPN client (in same process) ───┘
//
// IP packets that iOS hands us are injected into a gVisor channel link
// endpoint. TCP flows are accepted by gVisor's tcp.Forwarder and each
// connection is dialed through the SOCKS5 listener that the inner Tunnel
// brought up. Outbound IP packets (TCP ACKs etc.) are read back off the link
// endpoint and surfaced to Swift via a PacketCallback for writePackets.
//
// UDP is treated narrowly: queries to port 53 are shimmed as DNS-over-TCP
// through SOCKS5 to a public resolver (default 1.1.1.1), since SOCKS5-UDP
// associate is not supported by the upstream listener. All other UDP traffic
// is dropped — QUIC etc. will fall back to TCP.

package mobile

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/net/proxy"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	tcpipchecksum "gvisor.dev/gvisor/pkg/tcpip/checksum"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/icmp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

// PacketCallback receives outbound IP packets that the host (NEPacketTunnelFlow)
// should write to the device. Implemented on the Swift side.
type PacketCallback interface {
	OnPacket(data []byte)
}

// MTU inside the gVisor stack. Must match what the extension declares to iOS
// via NEPacketTunnelNetworkSettings.mtu.
const PacketTunnelMTU = 1500

// PacketTunnel owns one inner MasterDnsVPN Tunnel plus a gVisor netstack and
// glues them to NEPacketTunnelFlow. Safe to use from multiple Swift threads.
type PacketTunnel struct {
	tunnel *Tunnel
	stack  *stack.Stack
	linkEP *channel.Endpoint
	dialer proxy.Dialer

	mu          sync.Mutex
	callback    PacketCallback
	dnsResolver string

	cancel  context.CancelFunc
	done    chan struct{}
	running atomic.Bool

	// Traffic counters, surfaced to the host via the gomobile-friendly Bytes*
	// accessors. Updated by the TCP forwarder and the DNS-over-TCP shim.
	bytesUp           atomic.Int64
	bytesDown         atomic.Int64
	tcpFlowsAccepted  atomic.Int64
	tcpFlowsActive    atomic.Int64
	dnsQueriesHandled atomic.Int64
}

// NewPacketTunnel allocates a packet tunnel handle. It does not start any
// goroutines or bring up the inner MasterDnsVPN client.
func NewPacketTunnel() *PacketTunnel {
	return &PacketTunnel{
		tunnel:      NewTunnel(),
		dnsResolver: "1.1.1.1:53",
	}
}

// SetLogCallback forwards to the inner Tunnel.
func (pt *PacketTunnel) SetLogCallback(cb LogCallback) { pt.tunnel.SetLogCallback(cb) }

// SetStatusCallback forwards to the inner Tunnel.
func (pt *PacketTunnel) SetStatusCallback(cb StatusCallback) { pt.tunnel.SetStatusCallback(cb) }

// SetPacketCallback wires up the sink for outbound IP packets that Swift
// should hand to NEPacketTunnelFlow.writePackets.
func (pt *PacketTunnel) SetPacketCallback(cb PacketCallback) {
	pt.mu.Lock()
	pt.callback = cb
	pt.mu.Unlock()
}

// SetDNSResolver overrides the upstream DNS resolver that UDP-53 packets are
// shimmed onto (DNS-over-TCP through SOCKS5). Default 1.1.1.1:53. Address must
// be "host:port".
func (pt *PacketTunnel) SetDNSResolver(addr string) {
	pt.mu.Lock()
	pt.dnsResolver = addr
	pt.mu.Unlock()
}

// IsRunning reports whether the packet tunnel is currently up.
func (pt *PacketTunnel) IsRunning() bool { return pt.running.Load() }

// SocksAddress returns the inner SOCKS5 listener's address (rarely needed for
// the extension; useful in tests).
func (pt *PacketTunnel) SocksAddress() string { return pt.tunnel.SocksAddress() }

// BytesUp returns cumulative bytes that have flowed device→tunnel since
// Start (TCP payloads + DNS query bytes). Monotonic; reset on Start.
func (pt *PacketTunnel) BytesUp() int64 { return pt.bytesUp.Load() }

// BytesDown returns cumulative bytes that have flowed tunnel→device since
// Start (TCP payloads + DNS response bytes). Monotonic; reset on Start.
func (pt *PacketTunnel) BytesDown() int64 { return pt.bytesDown.Load() }

// TCPFlowsAccepted is the lifetime count of inbound TCP flows the forwarder
// dialed through SOCKS5. Includes flows that failed after CreateEndpoint.
func (pt *PacketTunnel) TCPFlowsAccepted() int64 { return pt.tcpFlowsAccepted.Load() }

// TCPFlowsActive is the current count of bidirectional TCP pipes the
// forwarder is keeping open.
func (pt *PacketTunnel) TCPFlowsActive() int64 { return pt.tcpFlowsActive.Load() }

// DNSQueriesHandled is the lifetime count of UDP-53 queries the
// DNS-over-TCP shim successfully resolved upstream.
func (pt *PacketTunnel) DNSQueriesHandled() int64 { return pt.dnsQueriesHandled.Load() }

// ResolversTotal forwards to the inner Tunnel's balancer-derived total
// resolver count. 0 before bootstrap.
func (pt *PacketTunnel) ResolversTotal() int { return pt.tunnel.ResolversTotal() }

// ResolversActive forwards to the inner Tunnel's balancer-derived active
// (in-rotation) resolver count.
func (pt *PacketTunnel) ResolversActive() int { return pt.tunnel.ResolversActive() }

// MTUSummary forwards to the inner Tunnel's MTU summary string (CSV form, see
// Tunnel.MTUSummary doc). Empty before bootstrap or while still probing.
func (pt *PacketTunnel) MTUSummary() string { return pt.tunnel.MTUSummary() }

// LastStatus returns the most recent status string emitted by the inner
// Tunnel (e.g. "mtu_testing", "connected", "error:..."). Empty before
// Start.
func (pt *PacketTunnel) LastStatus() string { return pt.tunnel.LastStatus() }

// Start brings up the inner MasterDnsVPN client, waits for its SOCKS5
// listener to become reachable, then spins up the gVisor netstack and starts
// the outbound packet pump. Non-blocking: returns once the netstack is ready.
func (pt *PacketTunnel) Start(configJSON, resolversText, scratchDir string) error {
	if !pt.running.CompareAndSwap(false, true) {
		return errors.New("packet tunnel already running")
	}
	if err := pt.startInner(configJSON, resolversText, scratchDir); err != nil {
		pt.running.Store(false)
		return err
	}
	return nil
}

func (pt *PacketTunnel) startInner(configJSON, resolversText, scratchDir string) error {
	pt.bytesUp.Store(0)
	pt.bytesDown.Store(0)
	pt.tcpFlowsAccepted.Store(0)
	pt.tcpFlowsActive.Store(0)
	pt.dnsQueriesHandled.Store(0)
	if err := pt.tunnel.Start(configJSON, resolversText, scratchDir); err != nil {
		return fmt.Errorf("inner tunnel: %w", err)
	}
	socksAddr := pt.tunnel.SocksAddress()
	if socksAddr == "" {
		_ = pt.tunnel.Stop()
		return errors.New("inner tunnel did not expose a SOCKS5 address")
	}
	if err := waitForListener(socksAddr, 15*time.Second); err != nil {
		_ = pt.tunnel.Stop()
		return fmt.Errorf("SOCKS5 not reachable: %w", err)
	}
	d, err := proxy.SOCKS5("tcp", socksAddr, nil, &net.Dialer{Timeout: 10 * time.Second})
	if err != nil {
		_ = pt.tunnel.Stop()
		return fmt.Errorf("socks dialer: %w", err)
	}
	pt.dialer = d

	s := stack.New(stack.Options{
		NetworkProtocols: []stack.NetworkProtocolFactory{
			ipv4.NewProtocol,
			ipv6.NewProtocol,
		},
		TransportProtocols: []stack.TransportProtocolFactory{
			tcp.NewProtocol,
			udp.NewProtocol,
			icmp.NewProtocol4,
			icmp.NewProtocol6,
		},
	})
	const nicID tcpip.NICID = 1
	ep := channel.New(512, PacketTunnelMTU, "")
	if tErr := s.CreateNIC(nicID, ep); tErr != nil {
		_ = pt.tunnel.Stop()
		return fmt.Errorf("create NIC: %s", tErr)
	}
	// Promiscuous + spoofing so the stack accepts packets for any destination
	// (we don't bind any IP to the NIC — we're a forwarder, not an endpoint).
	s.SetPromiscuousMode(nicID, true)
	s.SetSpoofing(nicID, true)
	s.SetRouteTable([]tcpip.Route{
		{Destination: header.IPv4EmptySubnet, NIC: nicID},
		{Destination: header.IPv6EmptySubnet, NIC: nicID},
	})

	// TCP forwarder: accepts SYNs, hands us each new flow.
	tcpFwd := tcp.NewForwarder(s, 0, 1024, pt.tcpHandler)
	s.SetTransportProtocolHandler(tcp.ProtocolNumber, tcpFwd.HandlePacket)

	pt.stack = s
	pt.linkEP = ep

	ctx, cancel := context.WithCancel(context.Background())
	pt.cancel = cancel
	pt.done = make(chan struct{})
	go pt.outboundLoop(ctx)
	return nil
}

// Stop tears down the gVisor stack and the inner tunnel. Safe to call twice.
func (pt *PacketTunnel) Stop() error {
	if !pt.running.CompareAndSwap(true, false) {
		return nil
	}
	if pt.cancel != nil {
		pt.cancel()
	}
	if pt.done != nil {
		<-pt.done
	}
	if pt.stack != nil {
		pt.stack.Close()
	}
	return pt.tunnel.Stop()
}

// WritePacket is called by Swift for every IP packet read from
// NEPacketTunnelFlow. The byte slice is consumed synchronously; the caller may
// reuse the underlying buffer after return.
func (pt *PacketTunnel) WritePacket(data []byte) {
	if !pt.running.Load() || pt.linkEP == nil || len(data) == 0 {
		return
	}
	if pt.tryInterceptDNS(data) {
		return
	}
	var proto tcpip.NetworkProtocolNumber
	switch data[0] >> 4 {
	case 4:
		proto = ipv4.ProtocolNumber
	case 6:
		proto = ipv6.ProtocolNumber
	default:
		return
	}
	// gVisor takes ownership of the buffer; copy because Swift may reuse it.
	cp := make([]byte, len(data))
	copy(cp, data)
	pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{
		Payload: buffer.MakeWithData(cp),
	})
	pt.linkEP.InjectInbound(proto, pkt)
	pkt.DecRef()
}

func (pt *PacketTunnel) outboundLoop(ctx context.Context) {
	defer close(pt.done)
	for {
		pkt := pt.linkEP.ReadContext(ctx)
		if pkt == nil {
			return
		}
		view := pkt.ToView()
		raw := view.AsSlice()
		out := make([]byte, len(raw))
		copy(out, raw)
		view.Release()
		pkt.DecRef()

		pt.mu.Lock()
		cb := pt.callback
		pt.mu.Unlock()
		if cb != nil {
			cb.OnPacket(out)
		}
	}
}

// tcpHandler is invoked once per inbound TCP SYN. We accept the connection,
// dial the original destination via SOCKS5, and bidirectionally pipe bytes.
func (pt *PacketTunnel) tcpHandler(r *tcp.ForwarderRequest) {
	id := r.ID()
	dst := net.JoinHostPort(addrString(id.LocalAddress), fmt.Sprintf("%d", id.LocalPort))

	var wq waiter.Queue
	ep, tErr := r.CreateEndpoint(&wq)
	if tErr != nil {
		r.Complete(true) // RST
		return
	}
	r.Complete(false)
	local := gonet.NewTCPConn(&wq, ep)

	go func() {
		remote, derr := pt.dialer.Dial("tcp", dst)
		if derr != nil {
			_ = local.Close()
			return
		}
		pt.tcpFlowsAccepted.Add(1)
		pt.tcpFlowsActive.Add(1)
		var halves sync.WaitGroup
		halves.Add(2)
		// local→remote is bytes the device sent out: "up".
		go func() {
			defer halves.Done()
			pipeAndCount(remote, local, &pt.bytesUp)
			_ = remote.Close()
			_ = local.Close()
		}()
		// remote→local is bytes the device received: "down".
		go func() {
			defer halves.Done()
			pipeAndCount(local, remote, &pt.bytesDown)
			_ = local.Close()
			_ = remote.Close()
		}()
		go func() {
			halves.Wait()
			pt.tcpFlowsActive.Add(-1)
		}()
	}()
}

func pipeAndCount(dst io.Writer, src io.Reader, counter *atomic.Int64) {
	buf := make([]byte, 32*1024)
	for {
		n, rerr := src.Read(buf)
		if n > 0 {
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return
			}
			counter.Add(int64(n))
		}
		if rerr != nil {
			return
		}
	}
}

// tryInterceptDNS catches UDP-53 datagrams before they reach gVisor and shims
// them onto DNS-over-TCP through SOCKS5. Returns true if the packet was
// handled (and must not be injected into the stack).
func (pt *PacketTunnel) tryInterceptDNS(data []byte) bool {
	var (
		src, dst         []byte
		srcPort, dstPort uint16
		payload          []byte
		isIPv6           bool
	)
	switch data[0] >> 4 {
	case 4:
		if len(data) < 28 {
			return false
		}
		if data[9] != 17 { // not UDP
			return false
		}
		ihl := int(data[0]&0x0f) * 4
		if len(data) < ihl+8 {
			return false
		}
		src = data[12:16]
		dst = data[16:20]
		udpHdr := data[ihl:]
		srcPort = binary.BigEndian.Uint16(udpHdr[0:2])
		dstPort = binary.BigEndian.Uint16(udpHdr[2:4])
		payload = udpHdr[8:]
	case 6:
		if len(data) < 48 {
			return false
		}
		if data[6] != 17 { // not UDP (ignores extension headers; rare on iOS DNS)
			return false
		}
		src = data[8:24]
		dst = data[24:40]
		udpHdr := data[40:]
		srcPort = binary.BigEndian.Uint16(udpHdr[0:2])
		dstPort = binary.BigEndian.Uint16(udpHdr[2:4])
		payload = udpHdr[8:]
		isIPv6 = true
	default:
		return false
	}
	if dstPort != 53 {
		return false
	}

	srcCopy := append([]byte(nil), src...)
	dstCopy := append([]byte(nil), dst...)
	payloadCopy := append([]byte(nil), payload...)
	pt.bytesUp.Add(int64(len(payloadCopy)))

	go func() {
		resp, err := pt.resolveDoT(payloadCopy)
		if err != nil || len(resp) == 0 {
			return
		}
		pt.dnsQueriesHandled.Add(1)
		// Response packet: from original destination → original source.
		out := buildUDPResponse(dstCopy, srcCopy, dstPort, srcPort, resp, isIPv6)
		if out == nil {
			return
		}
		pt.bytesDown.Add(int64(len(resp)))
		pt.mu.Lock()
		cb := pt.callback
		pt.mu.Unlock()
		if cb != nil {
			cb.OnPacket(out)
		}
	}()
	return true
}

func (pt *PacketTunnel) resolveDoT(query []byte) ([]byte, error) {
	pt.mu.Lock()
	resolver := pt.dnsResolver
	dialer := pt.dialer
	pt.mu.Unlock()
	if dialer == nil {
		return nil, errors.New("no dialer")
	}
	conn, err := dialer.Dial("tcp", resolver)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	type deadliner interface{ SetDeadline(time.Time) error }
	if dl, ok := conn.(deadliner); ok {
		_ = dl.SetDeadline(time.Now().Add(10 * time.Second))
	}

	// DNS-over-TCP: 2-byte length prefix (RFC 1035 §4.2.2).
	prefix := []byte{byte(len(query) >> 8), byte(len(query))}
	if _, err := conn.Write(append(prefix, query...)); err != nil {
		return nil, err
	}
	var lenBuf [2]byte
	if _, err := io.ReadFull(conn, lenBuf[:]); err != nil {
		return nil, err
	}
	respLen := int(binary.BigEndian.Uint16(lenBuf[:]))
	if respLen <= 0 || respLen > 65535 {
		return nil, fmt.Errorf("bad DNS response length: %d", respLen)
	}
	resp := make([]byte, respLen)
	if _, err := io.ReadFull(conn, resp); err != nil {
		return nil, err
	}
	return resp, nil
}

func buildUDPResponse(src, dst []byte, srcPort, dstPort uint16, payload []byte, isIPv6 bool) []byte {
	if isIPv6 {
		return buildIPv6UDP(src, dst, srcPort, dstPort, payload)
	}
	return buildIPv4UDP(src, dst, srcPort, dstPort, payload)
}

func buildIPv4UDP(src, dst []byte, srcPort, dstPort uint16, payload []byte) []byte {
	if len(src) != 4 || len(dst) != 4 {
		return nil
	}
	udpLen := header.UDPMinimumSize + len(payload)
	total := header.IPv4MinimumSize + udpLen
	pkt := make([]byte, total)

	srcAddr := tcpip.AddrFrom4Slice(src)
	dstAddr := tcpip.AddrFrom4Slice(dst)

	ip := header.IPv4(pkt[:header.IPv4MinimumSize])
	ip.Encode(&header.IPv4Fields{
		TotalLength: uint16(total),
		TTL:         64,
		Protocol:    uint8(header.UDPProtocolNumber),
		SrcAddr:     srcAddr,
		DstAddr:     dstAddr,
	})
	ip.SetChecksum(^ip.CalculateChecksum())

	udp := header.UDP(pkt[header.IPv4MinimumSize:])
	udp.Encode(&header.UDPFields{
		SrcPort: srcPort,
		DstPort: dstPort,
		Length:  uint16(udpLen),
	})
	copy(pkt[header.IPv4MinimumSize+header.UDPMinimumSize:], payload)
	sum := header.PseudoHeaderChecksum(header.UDPProtocolNumber, srcAddr, dstAddr, uint16(udpLen))
	sum = tcpipchecksum.Checksum(pkt[header.IPv4MinimumSize:], sum)
	udp.SetChecksum(^sum)
	return pkt
}

func buildIPv6UDP(src, dst []byte, srcPort, dstPort uint16, payload []byte) []byte {
	if len(src) != 16 || len(dst) != 16 {
		return nil
	}
	udpLen := header.UDPMinimumSize + len(payload)
	total := header.IPv6MinimumSize + udpLen
	pkt := make([]byte, total)

	srcAddr := tcpip.AddrFrom16Slice(src)
	dstAddr := tcpip.AddrFrom16Slice(dst)

	ip := header.IPv6(pkt[:header.IPv6MinimumSize])
	ip.Encode(&header.IPv6Fields{
		PayloadLength:     uint16(udpLen),
		TransportProtocol: header.UDPProtocolNumber,
		HopLimit:          64,
		SrcAddr:           srcAddr,
		DstAddr:           dstAddr,
	})

	udp := header.UDP(pkt[header.IPv6MinimumSize:])
	udp.Encode(&header.UDPFields{
		SrcPort: srcPort,
		DstPort: dstPort,
		Length:  uint16(udpLen),
	})
	copy(pkt[header.IPv6MinimumSize+header.UDPMinimumSize:], payload)
	sum := header.PseudoHeaderChecksum(header.UDPProtocolNumber, srcAddr, dstAddr, uint16(udpLen))
	sum = tcpipchecksum.Checksum(pkt[header.IPv6MinimumSize:], sum)
	udp.SetChecksum(^sum)
	return pkt
}

func addrString(a tcpip.Address) string {
	return net.IP(a.AsSlice()).String()
}

func waitForListener(addr string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		c, err := net.DialTimeout("tcp", addr, 1*time.Second)
		if err == nil {
			_ = c.Close()
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return fmt.Errorf("timeout waiting for %s", addr)
}
