import Foundation
import CoreVideo
import QuartzCore
import Libavcodec
import Libavformat
import Libavutil
import Libswscale
import Libswresample

// MARK: - Seek Logic
extension FFmpegDecoderCore {

    @discardableResult
    func seekAndQueueSingleFrame(to seconds: Double, seekId: Int, exact: Bool) async -> Double {
        guard let ctx = formatContext, let vCtx = videoCodecContext,
              let frame = av_frame_alloc(), let packet = av_packet_alloc(),
              let fallbackFrame = av_frame_alloc() else { return seconds }
        defer {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
            var p: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&p)
            var fb: UnsafeMutablePointer<AVFrame>? = fallbackFrame
            av_frame_free(&fb)
        }

        let timeBase = ctx.pointee.streams[Int(videoStreamIndex)]!.pointee.time_base
        var fallbackPTS: Double = seconds
        var hasFallback = false
        var count = 0
        let maxPackets = exact ? 500 : 30

        while count < maxPackets {
            if Task.isCancelled || seekId != self.activeSeekId {
                print("⏭️ Aborting obsolete seek (target: \(seconds), new target ID: \(self.activeSeekId))")
                break
            }

            await Task.yield()
            if Task.isCancelled || seekId != self.activeSeekId { break }

            av_packet_unref(packet)
            if av_read_frame(ctx, packet) < 0 { break }

            guard packet.pointee.stream_index == videoStreamIndex else {
                continue
            }

            var sendStatus = avcodec_send_packet(vCtx, packet)
            let gen = self.frameEmitGeneration  // capture once per packet iteration
            if sendStatus == -EAGAIN {
                // Decoder buffer is full, drain it first
                var found = false
                while avcodec_receive_frame(vCtx, frame) >= 0 {
                    let pts = Double(frame.pointee.best_effort_timestamp) * Double(timeBase.num) / Double(timeBase.den)
                    if !exact || pts >= seconds - 0.005 {
                        if seekId == self.activeSeekId {
                            if let pb = convertFrameToPixelBuffer(frame) {
                                self.startPlaybackTime = pts
                                let sendableBuffer = SendablePixelBuffer(buffer: pb, generation: gen)
                                self.videoFrameQueueCount += 1
                                let callback = self.onFrameReady
                                let capturePTS = pts
                                Task { @MainActor in
                                    callback?(sendableBuffer, capturePTS)
                                }
                            }
                        }
                        fallbackPTS = pts
                        found = true
                        av_frame_unref(frame)
                        break
                    }

                    av_frame_unref(fallbackFrame)
                    av_frame_ref(fallbackFrame, frame)
                    fallbackPTS = pts
                    hasFallback = true
                    av_frame_unref(frame)
                }
                if found {
                    return fallbackPTS
                }
                // Try sending again
                sendStatus = avcodec_send_packet(vCtx, packet)
            }

            if sendStatus >= 0 {
                var found = false
                while avcodec_receive_frame(vCtx, frame) >= 0 {
                    let pts = Double(frame.pointee.best_effort_timestamp) * Double(timeBase.num) / Double(timeBase.den)
                    if !exact || pts >= seconds - 0.005 {
                        if seekId == self.activeSeekId {
                            if let pb = convertFrameToPixelBuffer(frame) {
                                self.startPlaybackTime = pts
                                let sendableBuffer = SendablePixelBuffer(buffer: pb, generation: gen)
                                self.videoFrameQueueCount += 1
                                let callback = self.onFrameReady
                                let capturePTS = pts
                                Task { @MainActor in
                                    callback?(sendableBuffer, capturePTS)
                                }
                            }
                        }
                        fallbackPTS = pts
                        found = true
                        av_frame_unref(frame)
                        break
                    }

                    av_frame_unref(fallbackFrame)
                    av_frame_ref(fallbackFrame, frame)
                    fallbackPTS = pts
                    hasFallback = true
                    av_frame_unref(frame)
                }
                if found {
                    return fallbackPTS
                }
            }

            count += 1
        }

        // Fallback: If exact frame not reached or EOF, render the last decoded frame
        if hasFallback && seekId == self.activeSeekId {
            let gen = self.frameEmitGeneration
            if let pb = convertFrameToPixelBuffer(fallbackFrame) {
                self.startPlaybackTime = fallbackPTS
                let sendableBuffer = SendablePixelBuffer(buffer: pb, generation: gen)
                self.videoFrameQueueCount += 1
                let callback = self.onFrameReady
                let capturePTS = fallbackPTS
                Task { @MainActor in
                    callback?(sendableBuffer, capturePTS)
                }
            }
            return fallbackPTS
        }

        return seconds
    }

    func resampleAndQueueAudio(_ frame: UnsafeMutablePointer<AVFrame>, context: OpaquePointer, ctx: UnsafeMutablePointer<AVFormatContext>) {
        let swr = context
        let sampleCount = frame.pointee.nb_samples
        let audioPTS: Double? = {
            guard audioStreamIndex >= 0 else { return nil }
            let timestamp = frame.pointee.best_effort_timestamp
            guard timestamp != FFmpegDecoderCore.AV_NOPTS_VALUE else { return nil }
            let timeBase = ctx.pointee.streams[Int(audioStreamIndex)]!.pointee.time_base
            return Double(timestamp) * Double(timeBase.num) / Double(timeBase.den)
        }()

        let maxOutSamples = swr_get_delay(swr, 44100) + Int64(sampleCount)
        let capacity = Int(maxOutSamples)

        let leftBuffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        let rightBuffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)

        defer {
            leftBuffer.deallocate()
            rightBuffer.deallocate()
        }

        var outData: [UnsafeMutablePointer<UInt8>?] = [
            UnsafeMutablePointer<UInt8>(OpaquePointer(leftBuffer)),
            UnsafeMutablePointer<UInt8>(OpaquePointer(rightBuffer)),
            nil, nil, nil, nil, nil, nil
        ]

        let srcData = withUnsafePointer(to: &frame.pointee.data) { ptr in
            ptr.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { $0 }
        }

        let outSamples = swr_convert(
            swr,
            &outData,
            Int32(capacity),
            srcData,
            Int32(sampleCount)
        )

        if outSamples > 0 {
            let left = Array(UnsafeBufferPointer(start: leftBuffer, count: Int(outSamples)))
            let right = Array(UnsafeBufferPointer(start: rightBuffer, count: Int(outSamples)))
            let generation = frameEmitGeneration
            let callback = self.onAudioReady
            callback?(left, right, audioPTS, generation)
        }
    }
}
