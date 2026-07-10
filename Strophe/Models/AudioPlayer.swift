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
    private var schedulingGeneration: UInt = 0
    
    private let lock = NSLock()
    private let schedulingQueue = DispatchQueue(
        label: "com.strophe.ffmpeg.audio-scheduling",
        qos: .userInitiated
    )
    
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
        let pausedSampleTime: Int64? = {
            guard let nodeTime = playerNode.lastRenderTime,
                  let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return nil }
            return playerTime.sampleTime
        }()
        baseTime += elapsed
        if let pausedSampleTime {
            sampleTimeOffset = pausedSampleTime
        }
        lock.unlock()

        // Preserve scheduled buffers for ordinary pause/resume. A seek uses
        // seek(to:) below, which deliberately stops and clears the node.
        playerNode.pause()
    }
    
    func stop() {
        schedulingQueue.sync {
            playerNode.stop()
        }
        audioEngine.stop()
        lock.lock()
        isEngineRunning = false
        shouldBePlaying = false
        totalSamplesScheduled = 0
        scheduledBufferCount = 0
        baseTime = 0.0
        sampleTimeOffset = -1
        schedulingGeneration &+= 1
        lock.unlock()
    }
    
    func seek(to time: Double) {
        schedulingQueue.sync {
            // Stop outside the lock so completion handlers can finish safely.
            playerNode.stop()

            lock.lock()
            baseTime = time
            totalSamplesScheduled = 0
            scheduledBufferCount = 0
            sampleTimeOffset = -1
            schedulingGeneration &+= 1
            lock.unlock()
        }
        
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
        let generation = schedulingGeneration
        lock.unlock()

        schedulingQueue.async { [weak self] in
            self?.schedulePCMDataNow(
                left,
                right,
                presentationTime: presentationTime,
                generation: generation
            )
        }
    }

    private func schedulePCMDataNow(
        _ left: [Float],
        _ right: [Float],
        presentationTime: Double?,
        generation: UInt
    ) {
        lock.lock()
        guard generation == schedulingGeneration else {
            lock.unlock()
            return
        }
        
        let sampleCount = left.count
        guard sampleCount > 0 else {
            lock.unlock()
            return
        }
        
        let isFirstBuffer = totalSamplesScheduled == 0
        var leadingSilenceSamples = 0
        if isFirstBuffer {
            sampleTimeOffset = -1
            if let presentationTime, presentationTime.isFinite {
                let gap = max(0, min(2.0, presentationTime - baseTime))
                leadingSilenceSamples = Int((gap * sampleRate).rounded())
            }
        }
        let buffersToSchedule = leadingSilenceSamples > 0 ? 2 : 1
        scheduledBufferCount += buffersToSchedule
        let isPlayingState = shouldBePlaying
        let isCurrentlyPlaying = playerNode.isPlaying
        lock.unlock()
        
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 2,
                                   interleaved: false)!
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            lock.lock()
            scheduledBufferCount = max(0, scheduledBufferCount - buffersToSchedule)
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
        if leadingSilenceSamples > 0,
           let silenceBuffer = AVAudioPCMBuffer(
               pcmFormat: format,
               frameCapacity: AVAudioFrameCount(leadingSilenceSamples)
           ) {
            silenceBuffer.frameLength = AVAudioFrameCount(leadingSilenceSamples)
            if let channels = silenceBuffer.floatChannelData {
                memset(channels[0], 0, leadingSilenceSamples * MemoryLayout<Float>.size)
                memset(channels[1], 0, leadingSilenceSamples * MemoryLayout<Float>.size)
            }
            playerNode.scheduleBuffer(silenceBuffer) {
                guard let player = wrapper.player else { return }
                player.lock.lock()
                if generation == player.schedulingGeneration {
                    player.scheduledBufferCount = max(0, player.scheduledBufferCount - 1)
                }
                player.lock.unlock()
            }
        } else if leadingSilenceSamples > 0 {
            lock.lock()
            scheduledBufferCount = max(0, scheduledBufferCount - 1)
            lock.unlock()
            leadingSilenceSamples = 0
        }

        playerNode.scheduleBuffer(pcmBuffer) {
            guard let player = wrapper.player else { return }
            player.lock.lock()
            if generation == player.schedulingGeneration {
                player.scheduledBufferCount = max(0, player.scheduledBufferCount - 1)
            }
            player.lock.unlock()
        }
        
        lock.lock()
        totalSamplesScheduled += Int64(leadingSilenceSamples + sampleCount)
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
