import Foundation
import AVFoundation

/// Keeps the app process alive in the background by rendering silent audio
/// through AVAudioEngine. Required because the local SOCKS5 proxy lives inside
/// this app's process — iOS suspends regular apps ~30s after backgrounding,
/// and the listener dies with the process. With UIBackgroundModes=[audio] in
/// Info.plist and an active AVAudioSession in .playback, iOS treats DNSpire
/// as a media app and lets it keep running.
///
/// Only used by TunnelController (local-proxy mode). The system-VPN path
/// runs inside NEPacketTunnelProvider, which the extension subsystem keeps
/// alive on its own — no audio trick needed there.
///
/// Not thread-safe. Call from the main actor.
@MainActor
final class BackgroundAudioKeeper {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var active = false

    /// Activate playback session and start rendering silence. Idempotent.
    /// Failures are swallowed — the proxy still works in the foreground;
    /// background extension is best-effort.
    func start() {
        guard !active else { return }
        configureSession()
        installSilentSource()
        do {
            try engine.start()
            active = true
        } catch {
            // Engine refused to start (rare — usually device under heavy
            // memory pressure). Leave inactive; UI continues to function.
        }
    }

    /// Stop the engine and release the audio session so other apps' audio
    /// resumes normally. Idempotent.
    func stop() {
        guard active else { return }
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        active = false
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .mixWithOthers + zero volume means we don't interrupt music,
            // podcasts, or calls the user is already in. .playback alone
            // would duck or pause them.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // Even if session activation fails, we still attempt the engine —
            // best-effort. Without an active session, iOS will suspend us on
            // backgrounding anyway, but foreground use still works.
        }
    }

    private func installSilentSource() {
        guard sourceNode == nil else { return }
        let format = engine.outputNode.inputFormat(forBus: 0)
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in buffers {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        sourceNode = node
    }
}
