import AVFoundation
import Combine

/// One active stream across both windows. Observers and pending work belong to a
/// generation, so callbacks from a replaced player cannot mutate the new state.
@MainActor
final class PronunciationService: ObservableObject {
    static let shared = PronunciationService()
    enum State: Equatable { case idle, loading, playing, error }
    @Published private(set) var state = State.idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var owner: UUID?
    @Published private(set) var sourceID: UUID?
    private var player: AVPlayer?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var deadline: Task<Void, Never>?
    private var revision = UUID()

    func play(source: PronunciationSource, text: String, owner: UUID) {
        stop()
        self.owner = owner
        sourceID = source.id
        guard source.enabled, source.validationMessage == nil, let url = source.resolvedURL(text: text) else {
            fail(); return
        }
        state = .loading
        let token = revision
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 3
        let playback = AVPlayer(playerItem: item)
        player = playback
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor [weak self] in
                guard let self = self, self.revision == token else { return }
                if failed { self.fail() }
            }
        })
        observations.append(playback.observe(\.timeControlStatus, options: [.new]) { [weak self] playback, _ in
            let playing = playback.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self = self, self.revision == token else { return }
                self.state = playing ? .playing : .loading
                if playing { self.armDeadline(seconds: 300, token: token) }
                else { self.armDeadline(seconds: 30, token: token) }
            }
        })
        for name in [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.revision == token else { return }
                    if name == AVPlayerItem.didPlayToEndTimeNotification { self.stop() }
                    else { self.fail() }
                }
            })
        }
        armDeadline(seconds: 30, token: token)
        playback.play()
    }

    func stop(owner: UUID? = nil) {
        if let owner = owner, self.owner != owner { return }
        releasePlayback()
        state = .idle
        errorMessage = nil
        self.owner = nil
        sourceID = nil
    }

    private func armDeadline(seconds: UInt64, token: UUID) {
        deadline?.cancel()
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            guard let self = self, self.revision == token else { return }
            self.fail()
        }
    }

    private func fail() {
        releasePlayback()
        state = .error
        errorMessage = "发音加载或播放失败，请重试或切换来源。"
    }

    private func releasePlayback() {
        revision = UUID()
        deadline?.cancel(); deadline = nil
        observations.removeAll()
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        player?.pause()
        player?.currentItem?.asset.cancelLoading()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}
