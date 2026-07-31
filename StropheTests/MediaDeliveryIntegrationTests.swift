import AVFoundation
import VideoToolbox
import XCTest
@testable import Strophe

final class MediaDeliveryIntegrationTests: XCTestCase {
    func testMatroskaMuxCopiesVideoAndCreatesOneSubtitleStreamPerTrack() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StropheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("source.mov")
        let destinationURL = temporaryDirectory.appendingPathComponent("delivery.mkv")
        try await makeTestVideo(at: sourceURL)

        let tracks = [
            EmbeddedSubtitleTrack(
                id: UUID(),
                title: "English",
                languageCode: "en",
                cues: [
                    EmbeddedSubtitleCue(
                        startTime: 0.1,
                        endTime: 0.7,
                        text: "Hello"
                    )
                ]
            ),
            EmbeddedSubtitleTrack(
                id: UUID(),
                title: "中文",
                languageCode: "zh",
                cues: [
                    EmbeddedSubtitleCue(
                        startTime: 0.2,
                        endTime: 0.8,
                        text: "你好"
                    )
                ]
            ),
        ]

        try await EmbeddedSubtitleMediaMuxer.mux(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            tracks: tracks
        ) { _ in }

        let snapshot = try await MediaInformationProbe.load(from: destinationURL)
        let subtitleStreams = snapshot.streams.filter { $0.kind == .subtitle }

        XCTAssertEqual(snapshot.videoStreamCount, 1)
        XCTAssertEqual(subtitleStreams.count, 2)
        XCTAssertTrue(subtitleStreams.allSatisfy { $0.codecName == "subrip" })
        XCTAssertGreaterThan(
            try destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            0
        )

        let extractedURL = temporaryDirectory.appendingPathComponent("english.srt")
        let firstSubtitle = try XCTUnwrap(subtitleStreams.first)
        try await MediaStreamExtractionService.extract(
            stream: firstSubtitle,
            from: destinationURL,
            to: extractedURL
        )
        let extractedText = try String(contentsOf: extractedURL, encoding: .utf8)
        XCTAssertTrue(extractedText.contains("Hello"))
    }

    func testFFmpegHardExportHonorsRangeAndBurnInOptions() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StropheRangeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceMOV = temporaryDirectory.appendingPathComponent("source.mov")
        let sourceMKV = temporaryDirectory.appendingPathComponent("source.mkv")
        let destinationURL = temporaryDirectory.appendingPathComponent("range.mov")
        try await makeTestVideo(at: sourceMOV)
        try await EmbeddedSubtitleMediaMuxer.mux(
            sourceURL: sourceMOV,
            destinationURL: sourceMKV,
            tracks: [
                EmbeddedSubtitleTrack(
                    id: UUID(),
                    title: "Test",
                    languageCode: "en",
                    cues: [
                        EmbeddedSubtitleCue(
                            startTime: 0.1,
                            endTime: 0.8,
                            text: "Soft subtitle"
                        )
                    ]
                )
            ]
        ) { _ in }

        var settings = HardSubtitleVideoExportSettings()
        settings.codec = .proRes422
        settings.usesProjectRange = true
        settings.rangeStartSeconds = 0.1
        settings.rangeEndSeconds = 0.9
        settings.watermarkText = "Strophe"
        settings.burnsTimecode = true
        settings.timecodeStartsAtZero = true
        settings.includedAudioTrackOrdinals = []

        let reader = try FFmpegVideoExportVideoReader(url: sourceMKV)
        var decodedPresentationTimes: [Double] = []
        while let frame = try reader.nextFrame() {
            decodedPresentationTimes.append(frame.pts)
        }
        reader.close()
        XCTAssertTrue(
            decodedPresentationTimes.contains { $0 >= 0.1 && $0 < 0.9 },
            "Fixture must contain a frame in the requested export range: "
                + "\(decodedPresentationTimes)"
        )

        try await HardSubtitleVideoExporter.export(
            inputURL: sourceMKV,
            cues: [],
            settings: settings,
            destinationURL: destinationURL
        ) { _ in }

        let snapshot = try await MediaInformationProbe.load(from: destinationURL)
        XCTAssertEqual(snapshot.videoStreamCount, 1)
        XCTAssertNotNil(snapshot.duration)
        XCTAssertLessThanOrEqual(snapshot.duration ?? .greatestFiniteMagnitude, 1)
        XCTAssertGreaterThan(
            try destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            0
        )
    }

    func testFFmpegHardExportWithExternalAudioFixtureWhenProvided() async throws {
        guard
            let fixturePath = ProcessInfo.processInfo.environment[
                "STROPHE_FFMPEG_AUDIO_FIXTURE"
            ], !fixturePath.isEmpty
        else {
            throw XCTSkip(
                "Set STROPHE_FFMPEG_AUDIO_FIXTURE to exercise a real FFmpeg audio stream."
            )
        }
        let sourceURL = URL(fileURLWithPath: fixturePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("External FFmpeg audio fixture does not exist.")
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "StropheExternalAudioTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let destinationURL = temporaryDirectory.appendingPathComponent(
            "audio-regression.mp4"
        )
        var settings = HardSubtitleVideoExportSettings()
        settings.codec = .h264
        settings.usesProjectRange = true
        settings.rangeStartSeconds = 0
        settings.rangeEndSeconds = 5
        settings.includedAudioTrackOrdinals = [0]

        try await HardSubtitleVideoExporter.export(
            inputURL: sourceURL,
            cues: [],
            settings: settings,
            destinationURL: destinationURL
        ) { _ in }

        let snapshot = try await MediaInformationProbe.load(from: destinationURL)
        XCTAssertEqual(snapshot.videoStreamCount, 1)
        XCTAssertEqual(snapshot.audioStreamCount, 1)
        XCTAssertGreaterThan(
            try destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                ?? 0,
            0
        )
    }

    func testOptimizedAVFoundationPathsExportH264HEVCAndProRes() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "StropheCodecExportTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("source.mov")
        try await makeTestVideo(at: sourceURL)
        let cases: [(HardSubtitleVideoCodec, String)] = [
            (.h264, "h264"),
            (.h265, "hevc"),
            (.proRes422, "prores"),
        ]
        let cue = ResolvedSubtitleCue(
            id: UUID(),
            text: "GPU",
            startTime: 0.35,
            endTime: 0.65,
            style: .fallback,
            groupID: nil,
            trackIndex: 0,
            layer: 0,
            position: nil
        )

        for (codec, expectedCodecName) in cases {
            var settings = HardSubtitleVideoExportSettings()
            settings.codec = codec
            settings.includedAudioTrackOrdinals = []
            let destinationURL =
                temporaryDirectory
                .appendingPathComponent(codec.rawValue)
                .appendingPathExtension(codec.fileExtension)

            try await HardSubtitleVideoExporter.export(
                inputURL: sourceURL,
                cues: [cue],
                settings: settings,
                destinationURL: destinationURL
            ) { _ in }

            let snapshot = try await MediaInformationProbe.load(
                from: destinationURL
            )
            let videoStream = try XCTUnwrap(
                snapshot.streams.first { $0.kind == .video }
            )
            XCTAssertEqual(videoStream.codecName, expectedCodecName)
            XCTAssertGreaterThan(
                try destinationURL.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize ?? 0,
                0
            )

            let reader = try FFmpegVideoExportVideoReader(url: destinationURL)
            var presentationTimes: [Double] = []
            while let frame = try reader.nextFrame() {
                presentationTimes.append(frame.pts)
            }
            reader.close()
            XCTAssertEqual(presentationTimes.count, 6)
            XCTAssertTrue(
                zip(
                    presentationTimes,
                    presentationTimes.dropFirst()
                ).allSatisfy { $0.0 < $0.1 }
            )
        }
    }

    func testRenderPipelineDepthBalancesParallelismAndMemory() {
        var h264 = HardSubtitleVideoExportSettings()
        h264.codec = .h264
        XCTAssertEqual(
            HardSubtitleVideoExporter.renderPipelineDepth(
                settings: h264,
                renderSize: CGSize(width: 1_920, height: 1_080),
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                processorCount: 10,
                physicalMemory: 8 * 1_024 * 1_024 * 1_024
            ),
            5
        )

        var proRes = HardSubtitleVideoExportSettings()
        proRes.codec = .proRes422
        XCTAssertEqual(
            HardSubtitleVideoExporter.renderPipelineDepth(
                settings: proRes,
                renderSize: CGSize(width: 3_840, height: 2_160),
                pixelFormat: kCVPixelFormatType_32BGRA,
                processorCount: 10,
                physicalMemory: 8 * 1_024 * 1_024 * 1_024
            ),
            3
        )
        XCTAssertEqual(
            HardSubtitleVideoExporter.renderPipelineDepth(
                settings: proRes,
                renderSize: CGSize(width: 7_680, height: 4_320),
                pixelFormat: kCVPixelFormatType_32BGRA,
                processorCount: 10,
                physicalMemory: 8 * 1_024 * 1_024 * 1_024
            ),
            1
        )
    }

    #if os(macOS)
        func testAllCodecFamiliesPreferHardwareWithoutRequiringIt() throws {
            for codec in [
                HardSubtitleVideoCodec.h264,
                .h265,
                .proRes4444,
                .proRes422HQ,
                .proRes422,
                .proRes422LT,
                .proRes422Proxy,
            ] {
                let outputSettings = codec.outputSettings(
                    width: 1_920,
                    height: 1_080,
                    frameRate: 29.97,
                    exportSettings: HardSubtitleVideoExportSettings(codec: codec),
                    colorProfile: .sdr709
                )
                let specification = try XCTUnwrap(
                    outputSettings[AVVideoEncoderSpecificationKey]
                        as? [String: Any]
                )
                XCTAssertEqual(
                    specification[
                        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder
                            as String
                    ] as? Bool,
                    true
                )
                XCTAssertNil(
                    specification[
                        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder
                            as String
                    ]
                )
            }
        }

        func testSoftwareH264AndHEVCRateControlUsesSupportedProperties() throws {
            for codec in [HardSubtitleVideoCodec.h264, .h265] {
                var settings = HardSubtitleVideoExportSettings()
                settings.codec = codec
                settings.usesSoftwareEncoding = true
                settings.rateControlMode = .constantQuality

                let outputSettings = codec.outputSettings(
                    width: 1_920,
                    height: 1_080,
                    frameRate: 60,
                    exportSettings: settings,
                    colorProfile: .sdr709
                )
                let compressionProperties = try XCTUnwrap(
                    outputSettings[AVVideoCompressionPropertiesKey]
                        as? [String: Any]
                )
                XCTAssertNil(
                    compressionProperties["ConstantQualityFactor"]
                )
                if codec == .h265 {
                    XCTAssertNotNil(
                        compressionProperties[
                            kVTCompressionPropertyKey_Quality as String
                        ]
                    )
                } else {
                    XCTAssertNil(
                        compressionProperties[
                            kVTCompressionPropertyKey_Quality as String
                        ]
                    )
                    XCTAssertNotNil(
                        compressionProperties[
                            kVTCompressionPropertyKey_AverageBitRate as String
                        ]
                    )
                }
            }
        }

        func testSoftwareHEVCExportCompletes() async throws {
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "StropheSoftwareHEVCTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            let sourceURL = temporaryDirectory.appendingPathComponent("source.mov")
            let destinationURL = temporaryDirectory.appendingPathComponent(
                "software-hevc.mp4"
            )
            try await makeTestVideo(at: sourceURL)

            var settings = HardSubtitleVideoExportSettings()
            settings.codec = .h265
            settings.usesSoftwareEncoding = true
            settings.rateControlMode = .constantQuality
            settings.includedAudioTrackOrdinals = []
            try await HardSubtitleVideoExporter.export(
                inputURL: sourceURL,
                cues: [],
                settings: settings,
                destinationURL: destinationURL
            ) { _ in }

            let snapshot = try await MediaInformationProbe.load(from: destinationURL)
            XCTAssertEqual(
                snapshot.streams.first { $0.kind == .video }?.codecName,
                "hevc"
            )
            XCTAssertGreaterThan(
                try destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    ?? 0,
                0
            )
        }
    #endif
}

private enum TestMediaFixtureError: LocalizedError {
    case cannotAddVideoInput
    case cannotStartWriter(String)
    case missingPixelBufferPool
    case cannotAllocatePixelBuffer(CVReturn)
    case cannotAppendFrame(Int)
    case writerDidNotComplete(String)

    var errorDescription: String? {
        switch self {
        case .cannotAddVideoInput:
            "AVAssetWriter cannot add the test video input."
        case let .cannotStartWriter(message):
            "AVAssetWriter could not start: \(message)"
        case .missingPixelBufferPool:
            "AVAssetWriter did not create a pixel buffer pool."
        case let .cannotAllocatePixelBuffer(status):
            "Could not allocate a test video frame (CVReturn \(status))."
        case let .cannotAppendFrame(index):
            "Could not append test video frame \(index)."
        case let .writerDidNotComplete(message):
            "AVAssetWriter did not complete: \(message)"
        }
    }
}

private func makeTestVideo(at url: URL) async throws {
    try await Task.detached(priority: .userInitiated) {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAllowFrameReorderingKey: false
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        guard writer.canAdd(input) else {
            throw TestMediaFixtureError.cannotAddVideoInput
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw TestMediaFixtureError.cannotStartWriter(
                writer.error?.localizedDescription ?? "Unknown error"
            )
        }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            throw TestMediaFixtureError.missingPixelBufferPool
        }
        for frameIndex in 0..<6 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            let allocationStatus = CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pool,
                &buffer
            )
            guard allocationStatus == kCVReturnSuccess else {
                throw TestMediaFixtureError.cannotAllocatePixelBuffer(
                    allocationStatus
                )
            }
            guard let buffer else {
                throw TestMediaFixtureError.cannotAllocatePixelBuffer(
                    kCVReturnError
                )
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
                memset(baseAddress, 0, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard
                adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(
                        value: CMTimeValue(frameIndex),
                        timescale: 5
                    )
                )
            else {
                throw TestMediaFixtureError.cannotAppendFrame(frameIndex)
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw TestMediaFixtureError.writerDidNotComplete(
                writer.error?.localizedDescription ?? "Unknown error"
            )
        }
    }.value
}
