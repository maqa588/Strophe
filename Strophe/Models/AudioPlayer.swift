import Foundation
import AVFoundation

// MARK: - AudioPlayer
// Safe, high-precision manual buffer queuing and playback using AVAudioEngine + AVAudioPlayerNode
nonisolated final class AudioPlayer: @unchecked Sendable {
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitchNode = AVAudioUnitTimePitch()
    
    private var isEngineRunning = false
    private var shouldBePlaying = false
    private var baseTime: Double = 0.0
    private var totalSamplesScheduled: Int64 = 0
    private let sampleRate: Double = 44100.0
    private var scheduledBufferCount = 0
    
    /// Captures playerTime.sampleTime at the moment the first audio buffer
    /// arrives after a seek/play. All future elapsed calculations subtract
    /// this value, eliminating phantom time accumulated while FFmpeg was
    /// still decoding from an uncached position.
    private var sampleTimeOffset: Int64 = -1
    
    private let lock = NSLock()
    
    init() {
        setupAudioEngine()
    }
    
    private func setupAudioEngine() {
        audioEngine.attach(playerNode)
        audioEngine.attach(timePitchNode)
        
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 2,
                                   interleaved: false)!
        
        audioEngine.connect(playerNode, to: timePitchNode, format: format)
        audioEngine.connect(timePitchNode, to: audioEngine.mainMixerNode, format: format)
        timePitchNode.bypass = true
        audioEngine.prepare()
    }
    
    func start() {
        lock.lock()
        let nativelyRunning = audioEngine.isRunning
        lock.unlock()
        
        if !nativelyRunning {
            safeStartAudioEngine()
        }
    }
    
    private func safeStartAudioEngine() {
        var attempt = 0
        while attempt < 3 {
            do {
                try audioEngine.start()
                lock.lock()
                isEngineRunning = true
                lock.unlock()
                break
            } catch {
                let nsErr = error as NSError
                if nsErr.code == -4 || nsErr.code == 561015905 {
                    print("⚠️ AudioPlayer: audioEngine.start() threw \(nsErr.code) (InvalidRunState). Retrying in 50ms... (Attempt \(attempt + 1))")
                    Thread.sleep(forTimeInterval: 0.05)
                    attempt += 1
                } else {
                    print("❌ AudioPlayer: Failed to start audioEngine: \(error)")
                    break
                }
            }
        }
    }
    
    func play() {
        lock.lock()
        shouldBePlaying = true
        let hasSamples = totalSamplesScheduled > 0
        lock.unlock()
        
        start()
        if hasSamples {
            playerNode.play()
        }
    }
    
    func pause() {
        lock.lock()
        shouldBePlaying = false
        // Calculate real elapsed using offset-corrected sampleTime
        var elapsed = 0.0
        let isNodePlaying = playerNode.isPlaying
        if isNodePlaying, totalSamplesScheduled > 0 {
            if let nodeTime = playerNode.lastRenderTime,
               let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
                let corrected = max(0, playerTime.sampleTime - sampleTimeOffset)
                elapsed = Double(corrected) / sampleRate
            }
        }
        lock.unlock()
        
        // Call stop outside lock to allow scheduledBuffer's completion callback to acquire lock and run safely!
        playerNode.stop()
        
        lock.lock()
        baseTime += elapsed
        scheduledBufferCount = 0 // Reset buffer count since stop() clears all queued buffers
        lock.unlock()
    }
    
    func stop() {
        playerNode.stop()
        audioEngine.stop()
        isEngineRunning = false
        lock.lock()
        shouldBePlaying = false
        totalSamplesScheduled = 0
        scheduledBufferCount = 0
        baseTime = 0.0
        sampleTimeOffset = -1
        lock.unlock()
    }
    
    func seek(to time: Double) {
        playerNode.stop()
        
        lock.lock()
        baseTime = time
        totalSamplesScheduled = 0
        scheduledBufferCount = 0
        sampleTimeOffset = -1
        lock.unlock()
        
        if isEngineRunning {
            if !audioEngine.isRunning {
                safeStartAudioEngine()
            }
        }
    }
    
    func setRate(_ rate: Double) {
        lock.lock()
        defer { lock.unlock() }
        
        let safeRate = Float(max(1.0/32.0, min(rate, 32.0)))
        timePitchNode.rate = safeRate
        
        if abs(safeRate - 1.0) < 0.001 {
            timePitchNode.bypass = true
        } else {
            timePitchNode.bypass = false
        }
    }
    
    // Convert PCM data into AVAudioPCMBuffer and schedule it on the player node
    func schedulePCMData(_ left: [Float], _ right: [Float], presentationTime: Double? = nil) {
        lock.lock()
        
        let sampleCount = left.count
        guard sampleCount > 0 else {
            lock.unlock()
            return
        }
        
        if totalSamplesScheduled == 0, let presentationTime, presentationTime.isFinite {
            baseTime = presentationTime
            sampleTimeOffset = -1
        }
        scheduledBufferCount += 1
        let isPlayingState = shouldBePlaying
        let isCurrentlyPlaying = playerNode.isPlaying
        lock.unlock()
        
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 2,
                                   interleaved: false)!
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            lock.lock()
            scheduledBufferCount = max(0, scheduledBufferCount - 1)
            lock.unlock()
            return
        }
        
        pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)
        
        let leftDst = pcmBuffer.floatChannelData![0]
        let rightDst = pcmBuffer.floatChannelData![1]
        
        left.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                memcpy(leftDst, base, sampleCount * MemoryLayout<Float>.size)
            }
        }
        right.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                memcpy(rightDst, base, sampleCount * MemoryLayout<Float>.size)
            }
        }
        
        let wrapper = WeakAudioPlayerWrapper(player: self)
        playerNode.scheduleBuffer(pcmBuffer) {
            guard let player = wrapper.player else { return }
            player.lock.lock()
            player.scheduledBufferCount = max(0, player.scheduledBufferCount - 1)
            player.lock.unlock()
        }
        
        lock.lock()
        totalSamplesScheduled += Int64(sampleCount)
        lock.unlock()
        
        if isPlayingState && !isCurrentlyPlaying {
            playerNode.play()
        }
    }
    
    // Get the frame-perfect current time of the audio playback
    var currentTime: Double {
        lock.lock()
        defer { lock.unlock() }
        
        guard totalSamplesScheduled > 0,
              playerNode.isPlaying,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return baseTime
        }
        
        // Lazily snapshot the sampleTimeOffset at the exact first render tick of playback
        if sampleTimeOffset == -1 {
            sampleTimeOffset = playerTime.sampleTime
        }
        
        let elapsed = Double(max(0, playerTime.sampleTime - sampleTimeOffset)) / sampleRate
        return baseTime + elapsed
    }
    
    var isPlaying: Bool {
        return playerNode.isPlaying
    }
    
    var isPlayingAndRendering: Bool {
        lock.lock()
        let samplesScheduled = totalSamplesScheduled
        let offset = sampleTimeOffset
        lock.unlock()
        
        guard samplesScheduled > 0,
              playerNode.isPlaying,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return false
        }
        return playerTime.sampleTime > offset
    }
    
    var scheduledBuffers: Int {
        lock.lock()
        defer { lock.unlock() }
        return scheduledBufferCount
    }
}

private struct WeakAudioPlayerWrapper: @unchecked Sendable {
    weak var player: AudioPlayer?
}
