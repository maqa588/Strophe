import AVFoundation
import Foundation

struct FormatDetectionResult: Equatable, Sendable {
    let isAVFoundationCompatible: Bool
    let errorMessage: String?
    let hasVideoTrack: Bool
    let detectedFPS: Double?

    static let audioOnly = FormatDetectionResult(
        isAVFoundationCompatible: true,
        errorMessage: nil,
        hasVideoTrack: false,
        detectedFPS: nil
    )
}

@MainActor
final class FormatDetector {
    static let shared = FormatDetector()

    private var cache: [URL: FormatDetectionResult] = [:]

    private init() {}

    func cachedResult(for url: URL) -> FormatDetectionResult? {
        return cache[url]
    }

    func detect(url: URL) async -> FormatDetectionResult {
        if let cached = cache[url] {
            print("🔍 Format detection result (cached): \(cached.isAVFoundationCompatible) for \(url.lastPathComponent) (engine: \(cached.isAVFoundationCompatible ? "AVFoundation" : "FFmpeg"))")
            return cached
        }

        let ext = url.pathExtension.lowercased()
        let incompatibleExtensions = ["mkv", "webm", "rmvb", "avi", "flv"]
        if incompatibleExtensions.contains(ext) {
            let result = FormatDetectionResult(
                isAVFoundationCompatible: false,
                errorMessage: "Container not supported natively by AVFoundation",
                hasVideoTrack: true,
                detectedFPS: nil
            )
            cache[url] = result
            print("🔍 Format detection result: false for \(url.lastPathComponent) (engine: FFmpeg)")
            return result
        }

        let result = await probe(url: url)
        cache[url] = result
        print("🔍 Format detection result: \(result.isAVFoundationCompatible) for \(url.lastPathComponent) (engine: \(result.isAVFoundationCompatible ? "AVFoundation" : "FFmpeg"))")
        return result
    }

    func invalidate(url: URL) {
        cache.removeValue(forKey: url)
    }

    private func probe(url: URL) async -> FormatDetectionResult {
        let asset = AVURLAsset(url: url)

        do {
            let (tracks, _) = try await withThrowingTimeout(seconds: 5) {
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                return (videoTracks, ())
            }

            guard let videoTrack = tracks.first else {
                let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
                if audioTracks?.isEmpty ?? true {
                    return FormatDetectionResult(
                        isAVFoundationCompatible: false,
                        errorMessage: "No playable tracks found",
                        hasVideoTrack: false,
                        detectedFPS: nil
                    )
                }
                return .audioOnly
            }

            let fps = (try? await videoTrack.load(.nominalFrameRate)) ?? 30.0
            
            return FormatDetectionResult(
                isAVFoundationCompatible: true,
                errorMessage: nil,
                hasVideoTrack: true,
                detectedFPS: Double(fps)
            )
        } catch {
            return FormatDetectionResult(
                isAVFoundationCompatible: false,
                errorMessage: error.localizedDescription,
                hasVideoTrack: false,
                detectedFPS: nil
            )
        }
    }
}

private func withThrowingTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw FormatDetectorError.timeout
        }
        guard let result = try await group.next() else {
            throw FormatDetectorError.timeout
        }
        group.cancelAll()
        return result
    }
}

enum FormatDetectorError: Error {
    case timeout
}
