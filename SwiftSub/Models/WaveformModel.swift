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
    @Published var levels: [Int: [WaveformBin]] = [:]
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
        let data = WaveformData()
        
        Task.detached(priority: .userInitiated) {
            if let levels = await self.extractAndComputeBins(from: url, data: data) {
                await MainActor.run {
                    data.levels = levels
                }
            }
            
            await MainActor.run {
                completion(data)
            }
        }
    }
    
    private nonisolated func extractAndComputeBins(from url: URL, data: WaveformData) async -> [Int: [WaveformBin]]? {
        return await extractViaAVFoundation(url: url, data: data)
    }
    
    private nonisolated func extractViaAVFoundation(url: URL, data: WaveformData) async -> [Int: [WaveformBin]]? {
        let asset = AVURLAsset(url: url)
        
        guard let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first else { return nil }
        let durationValue = (try? await asset.load(.duration))?.seconds ?? 0
        
        let sampleRateValue: Double
        if let formats = try? await audioTrack.load(.formatDescriptions),
           let format = formats.first,
           let desc = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
            sampleRateValue = desc.pointee.mSampleRate
        } else {
            sampleRateValue = 44100.0
        }
        
        await MainActor.run {
            data.duration = durationValue
            data.sampleRate = sampleRateValue
        }
        
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)
        guard reader.startReading() else { return nil }
        
        var zoomBins220: [WaveformBin] = []
        var zoomBins880: [WaveformBin] = []
        var zoomBins4410: [WaveformBin] = []
        
        var leftOverSamples: [Float] = []
        let processChunkSize = 44100
        
        while reader.status == .reading {
            if let buffer = output.copyNextSampleBuffer(),
               let blockBuffer = buffer.dataBuffer {
                let length = blockBuffer.dataLength
                var samples = [Float](repeating: 0, count: length / 4)
                _ = samples.withUnsafeMutableBytes { bufferPointer in
                    try? blockBuffer.copyDataBytes(to: bufferPointer)
                }
                
                leftOverSamples.append(contentsOf: samples)
                
                while leftOverSamples.count >= processChunkSize {
                    let chunk = Array(leftOverSamples.prefix(processChunkSize))
                    leftOverSamples.removeFirst(processChunkSize)
                    
                    let bins220 = Self.computeBins(samples: chunk, samplesPerBin: 220)
                    let bins880 = Self.computeBins(samples: chunk, samplesPerBin: 880)
                    let bins4410 = Self.computeBins(samples: chunk, samplesPerBin: 4410)
                    
                    zoomBins220.append(contentsOf: bins220)
                    zoomBins880.append(contentsOf: bins880)
                    zoomBins4410.append(contentsOf: bins4410)
                }
            }
        }
        
        if !leftOverSamples.isEmpty {
            let bins220 = Self.computeBins(samples: leftOverSamples, samplesPerBin: 220)
            let bins880 = Self.computeBins(samples: leftOverSamples, samplesPerBin: 880)
            let bins4410 = Self.computeBins(samples: leftOverSamples, samplesPerBin: 4410)
            zoomBins220.append(contentsOf: bins220)
            zoomBins880.append(contentsOf: bins880)
            zoomBins4410.append(contentsOf: bins4410)
        }
        
        return [
            220: zoomBins220,
            880: zoomBins880,
            4410: zoomBins4410
        ]
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
                
                var peakPos: Float = 0
                vDSP_maxv(ptr, 1, &peakPos, vDSP_Length(count))
                
                var peakNeg: Float = 0
                vDSP_minv(ptr, 1, &peakNeg, vDSP_Length(count))
                
                var rms: Float = 0
                vDSP_rmsqv(ptr, 1, &rms, vDSP_Length(count))
                
                bins.append(WaveformBin(peakPositive: max(0, peakPos), peakNegative: min(0, peakNeg), rms: rms))
            }
        }
        
        return bins
    }
}
