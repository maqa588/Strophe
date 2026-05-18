//
//  WaveformModel.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/16.
//

import Foundation
import AVFoundation
import Accelerate
import Combine
import CoreMedia

struct WaveformBin: Codable {
    var peakPositive: Float
    var peakNegative: Float
    var rms: Float
}

@MainActor
class WaveformData: ObservableObject {
    @Published var levels: [Int: [WaveformBin]] = [:] // Key: samplesPerBin
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0
    
    var duration: Double = 0
    var sampleRate: Double = 44100
}

@MainActor
class WaveformProcessor {
    static let shared = WaveformProcessor()
    
    static let zoomLevels: [Int] = [220, 880, 4410]
    
    func process(url: URL, completion: @escaping @MainActor (WaveformData) -> Void) {
        let asset = AVURLAsset(url: url)
        let data = WaveformData()
        
        let zoomLevels = Self.zoomLevels // Capture zoomLevels before entering detached task
        
        Task.detached(priority: .userInitiated) {
            guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else { return }
            let durationValue = (try? await asset.load(.duration))?.seconds ?? 0
            
            let sampleRateValue: Double
            if let formats = try? await audioTrack.load(.formatDescriptions),
               let format = formats.first,
               let desc = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
                sampleRateValue = desc.pointee.mSampleRate
            } else {
                sampleRateValue = 44100.0
            }
            
            // Update data on MainActor
            await MainActor.run {
                data.duration = durationValue
                data.sampleRate = sampleRateValue
            }
            
            let reader = try? AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            reader?.add(output)
            reader?.startReading()
            
            var allSamples: [Float] = []
            
            while reader?.status == .reading {
                if let buffer = output.copyNextSampleBuffer(),
                   let blockBuffer = buffer.dataBuffer {
                    let length = blockBuffer.dataLength
                    var samples = [Float](repeating: 0, count: length / 4)
                    samples.withUnsafeMutableBytes { bufferPointer in
                        try? blockBuffer.copyDataBytes(to: bufferPointer)
                    }
                    allSamples.append(contentsOf: samples)
                }
            }
            
            if allSamples.isEmpty { return }
            
            // 计算多级缓存
            for samplesPerBin in zoomLevels {
                let bins = Self.computeBins(samples: allSamples, samplesPerBin: samplesPerBin)
                await MainActor.run {
                    data.levels[samplesPerBin] = bins
                }
            }
            
            await MainActor.run {
                completion(data)
            }
        }
    }
    
    nonisolated static private func computeBins(samples: [Float], samplesPerBin: Int) -> [WaveformBin] {
        let binCount = samples.count / samplesPerBin
        var bins: [WaveformBin] = []
        bins.reserveCapacity(binCount)
        
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            
            for i in 0..<binCount {
                let start = i * samplesPerBin
                let count = samplesPerBin
                let ptr = baseAddress.advanced(by: start)
                
                // Peak Positive
                var peakPos: Float = 0
                vDSP_maxv(ptr, 1, &peakPos, vDSP_Length(count))
                
                // Peak Negative
                var peakNeg: Float = 0
                vDSP_minv(ptr, 1, &peakNeg, vDSP_Length(count))
                
                // RMS (Using Accelerate for performance)
                var rms: Float = 0
                vDSP_rmsqv(ptr, 1, &rms, vDSP_Length(count))
                
                bins.append(WaveformBin(peakPositive: max(0, peakPos), peakNegative: min(0, peakNeg), rms: rms))
            }
        }
        
        return bins
    }
}
