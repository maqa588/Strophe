import SwiftUI
import AVFoundation

#if os(macOS)
typealias NativeView = NSView
#else
typealias NativeView = UIView
#endif

@MainActor
protocol PlayerEngine: AnyObject, Sendable {
    var playerView: NativeView { get }
    var currentTime: Double { get }
    var duration: Double { get }
    var rate: Double { get set }
    var fps: Double { get async }
    var videoSize: CGSize { get async }
    var isRenderingAndPlaying: Bool { get }

    @discardableResult
    func load(url: URL) async -> Bool
    func play()
    func pause()
    @discardableResult
    func seek(to time: Double) async -> Bool
    @discardableResult
    func seekExactly(to time: Double) async -> Bool
    @discardableResult
    func seekVideoFrameOnly(to time: Double) async -> Bool
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

@MainActor
final class AVFoundationEngine: PlayerEngine {
    private let player = AVPlayer()
    private let playerLayer: AVPlayerLayer
    private let hostView: NativeView
    private let engineID = UUID()
    private var itemID: UUID?
    private var seekGeneration: UInt = 0
    private var nominalFrameRate: Double = 30.0
    private var lastPreviewDiagnosticTime: CFAbsoluteTime = 0

    var playerRef: AVPlayer { player }

    init() {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect

        let view = AVPlayerHostView(playerLayer: layer)
        self.hostView = view
        self.playerLayer = layer

        log("initialized")
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

    @discardableResult
    func load(url: URL) async -> Bool {
        let item = AVPlayerItem(url: url)
        let newItemID = UUID()
        itemID = newItemID
        player.replaceCurrentItem(with: item)
        logState("load requested", item: item)

        let deadline = ContinuousClock.now + .seconds(15)
        while item.status == .unknown, ContinuousClock.now < deadline {
            guard !Task.isCancelled, player.currentItem === item, itemID == newItemID else {
                logState("load cancelled or superseded", item: item)
                return false
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        guard !Task.isCancelled, player.currentItem === item, itemID == newItemID else {
            logState("load cancelled or superseded", item: item)
            return false
        }

        guard item.status == .readyToPlay else {
            logState(item.status == .failed ? "load failed" : "load timed out", item: item)
            return false
        }

        if let videoTrack = try? await item.asset.loadTracks(withMediaType: .video).first,
           let frameRate = try? await videoTrack.load(.nominalFrameRate),
           frameRate.isFinite,
           frameRate > 0 {
            nominalFrameRate = Double(frameRate)
        }

        logState("ready to play", item: item)
        return true
    }

    func play() {
        player.rate = 1.0
    }

    func pause() {
        player.rate = 0.0
    }

    @discardableResult
    func seek(to time: Double) async -> Bool {
        let tolerance = halfFrameTolerance
        return await seek(
            to: time,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance,
            kind: .regular
        )
    }

    @discardableResult
    func seekExactly(to time: Double) async -> Bool {
        await seek(
            to: time,
            toleranceBefore: .zero,
            toleranceAfter: .zero,
            kind: .exact
        )
    }

    @discardableResult
    func seekVideoFrameOnly(to time: Double) async -> Bool {
        player.rate = 0.0 // Pause during scrub to prevent rapid AudioQueue start/stop (-4 errors)
        let tolerance = halfFrameTolerance
        return await seek(
            to: time,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance,
            kind: .preview
        )
    }

    func stop() {
        seekGeneration &+= 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        log("stopped item=\(shortID(itemID))")
        itemID = nil
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
    private func seek(
        to time: Double,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        kind: SeekKind
    ) async -> Bool {
        guard time.isFinite, let item = player.currentItem, item.status == .readyToPlay else {
            logState("seek rejected target=\(formatted(time))", item: player.currentItem)
            return false
        }

        seekGeneration &+= 1
        let generation = seekGeneration
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)

        let finished = await player.seek(
            to: cmTime,
            toleranceBefore: toleranceBefore,
            toleranceAfter: toleranceAfter
        )
        let isLatest = generation == seekGeneration
        let succeeded = finished && isLatest && player.currentItem === item
        if shouldLogSeek(kind: kind, succeeded: succeeded) {
            logState(
                "seek kind=\(kind.rawValue) target=\(formatted(time)) "
                + "finished=\(finished) latest=\(isLatest) current=\(formatted(currentTime))",
                item: item
            )
        }
        return succeeded
    }

    private enum SeekKind: String {
        case regular
        case exact
        case preview
    }

    private func shouldLogSeek(kind: SeekKind, succeeded: Bool) -> Bool {
        guard kind == .preview, succeeded else { return true }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPreviewDiagnosticTime >= 0.5 else { return false }
        lastPreviewDiagnosticTime = now
        return true
    }

    private var halfFrameTolerance: CMTime {
        let fps = nominalFrameRate.isFinite && nominalFrameRate > 0 ? nominalFrameRate : 30.0
        return CMTime(seconds: 0.5 / fps, preferredTimescale: 60_000)
    }

    private func logState(_ event: String, item: AVPlayerItem?) {
        let status: String
        switch item?.status {
        case .unknown: status = "unknown"
        case .readyToPlay: status = "readyToPlay"
        case .failed: status = "failed"
        case nil: status = "nil"
        @unknown default: status = "future"
        }

        let videoTracks = item?.tracks.filter {
            $0.assetTrack?.mediaType == .video
        } ?? []
        let enabledVideoTracks = videoTracks.filter(\.isEnabled).count
        let itemError = item?.error?.localizedDescription ?? "none"
        let playerError = player.error?.localizedDescription ?? "none"
        log(
            "\(event) item=\(shortID(itemID)) status=\(status) "
            + "videoTracks=\(videoTracks.count) enabledVideoTracks=\(enabledVideoTracks) "
            + "readyForDisplay=\(playerLayer.isReadyForDisplay) "
            + "itemError=\(itemError) playerError=\(playerError)"
        )
    }

    private func log(_ message: String) {
        print("🎞️ AVFoundationEngine[\(shortID(engineID))] \(message)")
    }

    private func shortID(_ id: UUID?) -> String {
        id.map { String($0.uuidString.prefix(8)) } ?? "nil"
    }

    private func formatted(_ time: Double) -> String {
        time.isFinite ? String(format: "%.3f", time) : "nonfinite"
    }
}
