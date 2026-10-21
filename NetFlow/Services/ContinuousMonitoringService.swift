import AVFoundation
import Foundation

/// Experimental sideload mode, not a guarantee of permanent background execution.
/// Generates silent PCM locally. No recording, microphone permission or network.
@MainActor
final class ContinuousMonitoringService: NSObject {
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private(set) var requested = false
    private(set) var isRunning = false
    private(set) var status = "连续采样未开启"
    var onChange: (() -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [AVAudioSession.interruptionNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in self?.handle(note) }
            })
        }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func setEnabled(_ enabled: Bool) {
        requested = enabled
        guard enabled else {
            player?.stop()
            player = nil
            isRunning = false
            status = "连续采样未开启"
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            onChange?()
            return
        }
        start()
    }

    func resumeIfRequested() {
        if requested && player?.isPlaying != true { start() }
    }

    func checkPlayback() {
        if isRunning && player?.isPlaying != true {
            isRunning = false
            status = "连续采样已中断，当前统计可能有空档"
            onChange?()
        }
    }

    private func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let audio = try AVAudioPlayer(data: Self.silenceWAV())
            audio.numberOfLoops = -1
            audio.prepareToPlay()
            guard audio.play() else { throw PlaybackError.failed }
            player = audio
            isRunning = true
            status = "连续采样运行中（实验）"
        } catch {
            isRunning = false
            status = "连续采样启动失败：\(error.localizedDescription)"
        }
        onChange?()
    }

    private func handle(_ notification: Notification) {
        guard requested else { return }
        if notification.name == AVAudioSession.mediaServicesWereResetNotification {
            player = nil
            start()
            return
        }
        let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
        if type == AVAudioSession.InterruptionType.began.rawValue {
            isRunning = false
            status = "音频会话被中断，连续采样暂停"
            onChange?()
        } else {
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { start() }
        }
    }

    private enum PlaybackError: Error { case failed }

    nonisolated static func silenceWAV() -> Data {
        let sampleRate: UInt32 = 8_000
        let pcmBytes: UInt32 = sampleRate * 2
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); u32(36 + pcmBytes); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        ascii("data"); u32(pcmBytes)
        data.append(Data(repeating: 0, count: Int(pcmBytes)))
        return data
    }
}
