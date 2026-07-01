import SwiftUI
import AVFoundation

#if os(macOS)
typealias NativeView = NSView
#else
typealias NativeView = UIView
#endif

protocol PlayerEngine: AnyObject {
    var playerView: NativeView { get }
    var currentTime: Double { get }
    var duration: Double { get }
    var rate: Double { get set }
    var fps: Double { get async }
    var videoSize: CGSize { get async }
    var isRenderingAndPlaying: Bool { get }

    func load(url: URL) async
    func play()
    func pause()
    func seek(to time: Double) async
    func seekVideoFrameOnly(to time: Double) async
    func stop()
}

#if os(macOS)
import AppKit
import QuartzCore
final class AVPlayerHostView: NSView {
    private let playerLayer: AVPlayerLayer
    
    init(playerLayer: AVPlayerLayer) {
        self.playerLayer = playerLayer
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        self.layer?.contentsScale = scale
        playerLayer.contentsScale = scale
        
        self.layer?.addSublayer(playerLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2.0
        self.layer?.contentsScale = scale
        playerLayer.contentsScale = scale
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let win = window {
            let scale = win.backingScaleFactor
            self.layer?.contentsScale = scale
            playerLayer.contentsScale = scale
        }
    }
    
    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
#else
import UIKit
import QuartzCore
final class AVPlayerHostView: UIView {
    private let playerLayer: AVPlayerLayer
    
    init(playerLayer: AVPlayerLayer) {
        self.playerLayer = playerLayer
        super.init(frame: .zero)
        self.backgroundColor = .black
        self.layer.addSublayer(playerLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
#endif

final class AVFoundationEngine: PlayerEngine {
    private let player = AVPlayer()
    private let playerLayer: AVPlayerLayer
    private let hostView: NativeView
    private let seekCoordinator = AVPlayerSeekCoordinator()

    var playerRef: AVPlayer { player }

    init() {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect

        let view = AVPlayerHostView(playerLayer: layer)
        self.hostView = view
        self.playerLayer = layer
    }

    var playerView: NativeView { hostView }

    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var isRenderingAndPlaying: Bool {
        return true
    }

    var duration: Double {
        guard let item = player.currentItem else { return 0 }
        let d = item.duration.seconds
        return d.isNaN || d.isInfinite ? 0 : d
    }

    var fps: Double {
        get async {
            guard let track = player.currentItem?.tracks.first(where: { $0.assetTrack?.mediaType == .video })?.assetTrack else {
                return 30.0
            }
            if #available(macOS 13, *) {
                do {
                    return Double(try await track.load(.nominalFrameRate))
                } catch {
                    return 30.0
                }
            } else {
                // Fallback on earlier versions
                return Double(track.nominalFrameRate)
            }
        }
    }

    var videoSize: CGSize {
        get async {
            guard let track = player.currentItem?.tracks.first(where: { $0.assetTrack?.mediaType == .video })?.assetTrack else {
                return .zero
            }
            if #available(macOS 13, *) {
                do {
                    return try await track.load(.naturalSize)
                } catch {
                    return .zero
                }
            } else {
                // Fallback on earlier versions
                return track.naturalSize
            }
        }
    }

    var rate: Double {
        get { Double(player.rate) }
        set { player.rate = Float(newValue.isFinite ? newValue : 0) }
    }

    func load(url: URL) async {
        let item = AVPlayerItem(url: url)
        await MainActor.run { player.replaceCurrentItem(with: item) }
    }

    func play() {
        player.rate = 1.0
    }

    func pause() {
        player.rate = 0.0
    }

    func seek(to time: Double) async {
        await seek(
            to: time,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func seekVideoFrameOnly(to time: Double) async {
        await MainActor.run {
            player.rate = 0.0 // Pause during scrub to prevent rapid AudioQueue start/stop (-4 errors)
        }
        await seek(
            to: time,
            toleranceBefore: CMTime(value: 1, timescale: 30),
            toleranceAfter: CMTime(value: 1, timescale: 30)
        )
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func addPeriodicTimeObserver(interval: CMTime, queue: DispatchQueue, using block: @escaping @Sendable (CMTime) -> Void) -> Any {
        return player.addPeriodicTimeObserver(forInterval: interval, queue: queue, using: { time in
            block(time)
        })
    }

    func removeTimeObserver(_ token: Any) {
        player.removeTimeObserver(token)
    }

    @discardableResult
    private func seek(to time: Double, toleranceBefore: CMTime, toleranceAfter: CMTime) async -> Bool {
        guard time.isFinite else { return false }
        let token = await seekCoordinator.nextToken()
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)

        await MainActor.run {
            player.currentItem?.cancelPendingSeeks()
        }

        let finished = await player.seek(
            to: cmTime,
            toleranceBefore: toleranceBefore,
            toleranceAfter: toleranceAfter
        )
        let isLatest = await seekCoordinator.isLatest(token)
        return finished && isLatest
    }
}

private actor AVPlayerSeekCoordinator {
    private var token = 0

    func nextToken() -> Int {
        token += 1
        return token
    }

    func isLatest(_ candidate: Int) -> Bool {
        candidate == token
    }
}
