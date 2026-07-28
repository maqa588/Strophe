import Combine
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct EmbeddedSubtitleCue: Sendable, Equatable {
    let startTime: Double
    let endTime: Double
    let text: String
}

nonisolated struct EmbeddedSubtitleTrack: Sendable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let languageCode: String?
    let cues: [EmbeddedSubtitleCue]
}

extension UTType {
    static nonisolated let stropheMatroskaVideo =
        UTType(filenameExtension: "mkv")
        ?? UTType(importedAs: "org.matroska.mkv")
}

struct MediaContainerExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.stropheMatroskaVideo] }
    static var writableContentTypes: [UTType] { [.stropheMatroskaVideo] }

    init() {}
    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}

enum EmbeddedSubtitleMuxError: LocalizedError {
    case noTimedSubtitles
    case cannotOpenInput
    case cannotReadStreams
    case cannotCreateOutput
    case noCompatibleMediaStreams
    case cannotWriteHeader(String)
    case cannotWritePacket(String)

    var errorDescription: String? {
        switch self {
        case .noTimedSubtitles:
            return String(localized: "embedded_subtitle_no_timed_cues")
        case .cannotOpenInput:
            return String(localized: "media_extract_cannot_open")
        case .cannotReadStreams:
            return String(localized: "media_extract_cannot_read_streams")
        case .cannotCreateOutput:
            return String(localized: "embedded_subtitle_cannot_create_output")
        case .noCompatibleMediaStreams:
            return String(localized: "embedded_subtitle_no_media_streams")
        case .cannotWriteHeader(let detail):
            return String.localizedStringWithFormat(
                String(localized: "embedded_subtitle_header_failed_format"),
                detail
            )
        case .cannotWritePacket(let detail):
            return String.localizedStringWithFormat(
                String(localized: "embedded_subtitle_write_failed_format"),
                detail
            )
        }
    }
}

@MainActor
enum EmbeddedSubtitleTrackBuilder {
    static func tracks(
        for project: SubtitleProject,
        store: StyleAndGroupStore = .shared
    ) -> [EmbeddedSubtitleTrack] {
        let eligibleItems = project.items.filter { item in
            guard !item.isHidden,
                  let start = item.startTime,
                  let end = item.endTime,
                  start.isFinite,
                  end.isFinite,
                  end > start else {
                return false
            }
            guard let group = store.group(id: item.groupID) else {
                return true
            }
            switch group.exportPolicy {
            case .includeInAllExports, .textOnly:
                return true
            case .burnedInOnly, .excludeByDefault, .referenceOnly:
                return false
            }
        }

        var orderedGroupIDs = store.sortedGroups.map(\.id)
        for groupID in eligibleItems.compactMap(\.groupID)
        where !orderedGroupIDs.contains(groupID) {
            orderedGroupIDs.append(groupID)
        }

        var tracks: [EmbeddedSubtitleTrack] = orderedGroupIDs.compactMap { groupID in
            let groupItems = eligibleItems
                .filter { $0.groupID == groupID }
                .sorted(by: project.stableSubtitleSort)
            guard !groupItems.isEmpty else { return nil }
            let group = store.group(id: groupID)
            return makeTrack(
                id: groupID,
                title: group?.subName.isEmpty == false
                    ? "\(group?.name ?? "") · \(group?.subName ?? "")"
                    : (group?.name ?? String(localized: "embedded_subtitle_default_track")),
                items: groupItems
            )
        }

        let ungroupedItems = eligibleItems
            .filter { $0.groupID == nil }
            .sorted(by: project.stableSubtitleSort)
        if !ungroupedItems.isEmpty {
            tracks.append(
                makeTrack(
                    id: UUID(),
                    title: String(localized: "embedded_subtitle_default_track"),
                    items: ungroupedItems
                )
            )
        }
        return tracks
    }

    private static func makeTrack(
        id: UUID,
        title: String,
        items: [SubtitleItem]
    ) -> EmbeddedSubtitleTrack {
        let languageCode = items
            .compactMap(\.languageCode)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let cues = items.compactMap { item -> EmbeddedSubtitleCue? in
            guard let start = item.startTime, let end = item.endTime else {
                return nil
            }
            return EmbeddedSubtitleCue(
                startTime: start,
                endTime: end,
                text: item.text
            )
        }
        return EmbeddedSubtitleTrack(
            id: id,
            title: title,
            languageCode: languageCode,
            cues: cues
        )
    }
}

/// Creates a Matroska delivery master by copying the source media packets and
/// adding one switchable SubRip stream for every exportable subtitle group.
/// Video and audio are not transcoded.
nonisolated enum EmbeddedSubtitleMediaMuxer {
    private static let noTimestamp = Int64(bitPattern: 0x8000000000000000)
    private static let subtitleTimeBase = AVRational(num: 1, den: 1_000)

    static func mux(
        sourceURL: URL,
        destinationURL: URL,
        tracks: [EmbeddedSubtitleTrack],
        progress: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws {
        guard tracks.contains(where: { !$0.cues.isEmpty }) else {
            throw EmbeddedSubtitleMuxError.noTimedSubtitles
        }

        try await Task.detached(priority: .userInitiated) {
            try await muxPackets(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                tracks: tracks,
                progress: progress
            )
        }.value
    }

    private static func muxPackets(
        sourceURL: URL,
        destinationURL: URL,
        tracks: [EmbeddedSubtitleTrack],
        progress: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws {
        let inputAccess = sourceURL.startAccessingSecurityScopedResource()
        let outputAccess = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if inputAccess { sourceURL.stopAccessingSecurityScopedResource() }
            if outputAccess { destinationURL.stopAccessingSecurityScopedResource() }
        }

        var input: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(
            &input,
            sourceURL.resolvingSymlinksInPath().path,
            nil,
            nil
        ) >= 0, let input else {
            throw EmbeddedSubtitleMuxError.cannotOpenInput
        }
        defer {
            var value: UnsafeMutablePointer<AVFormatContext>? = input
            avformat_close_input(&value)
        }
        guard avformat_find_stream_info(input, nil) >= 0 else {
            throw EmbeddedSubtitleMuxError.cannotReadStreams
        }

        try? FileManager.default.removeItem(at: destinationURL)
        var didFinish = false
        defer {
            if !didFinish {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        var output: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(
            &output,
            nil,
            "matroska",
            destinationURL.path
        ) >= 0, let output else {
            throw EmbeddedSubtitleMuxError.cannotCreateOutput
        }
        defer {
            if output.pointee.pb != nil {
                avio_closep(&output.pointee.pb)
            }
            avformat_free_context(output)
        }

        var streamMap: [Int32: Int32] = [:]
        for index in 0..<input.pointee.nb_streams {
            guard let inputStream = input.pointee.streams[Int(index)],
                  let inputParameters = inputStream.pointee.codecpar else {
                continue
            }
            let mediaType = inputParameters.pointee.codec_type
            guard mediaType == AVMEDIA_TYPE_VIDEO
                    || mediaType == AVMEDIA_TYPE_AUDIO
                    || mediaType == AVMEDIA_TYPE_SUBTITLE
                    || mediaType == AVMEDIA_TYPE_ATTACHMENT else {
                continue
            }
            guard let outputStream = avformat_new_stream(output, nil),
                  let outputParameters = outputStream.pointee.codecpar,
                  avcodec_parameters_copy(outputParameters, inputParameters) >= 0 else {
                throw EmbeddedSubtitleMuxError.cannotCreateOutput
            }
            outputParameters.pointee.codec_tag = 0
            outputStream.pointee.time_base = inputStream.pointee.time_base
            outputStream.pointee.disposition = inputStream.pointee.disposition
            av_dict_copy(
                &outputStream.pointee.metadata,
                inputStream.pointee.metadata,
                0
            )
            streamMap[Int32(index)] = outputStream.pointee.index
        }
        guard !streamMap.isEmpty else {
            throw EmbeddedSubtitleMuxError.noCompatibleMediaStreams
        }

        var subtitleOutputStreams: [UnsafeMutablePointer<AVStream>] = []
        for (index, track) in tracks.enumerated() where !track.cues.isEmpty {
            guard let outputStream = avformat_new_stream(output, nil),
                  let parameters = outputStream.pointee.codecpar else {
                throw EmbeddedSubtitleMuxError.cannotCreateOutput
            }
            parameters.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
            parameters.pointee.codec_id = AV_CODEC_ID_SUBRIP
            parameters.pointee.codec_tag = 0
            outputStream.pointee.time_base = subtitleTimeBase
            if index == 0 {
                outputStream.pointee.disposition |= AV_DISPOSITION_DEFAULT
            }
            av_dict_set(&outputStream.pointee.metadata, "title", track.title, 0)
            if let languageCode = track.languageCode, !languageCode.isEmpty {
                av_dict_set(
                    &outputStream.pointee.metadata,
                    "language",
                    languageCode,
                    0
                )
            }
            subtitleOutputStreams.append(outputStream)
        }

        guard avio_open(
            &output.pointee.pb,
            destinationURL.path,
            AVIO_FLAG_WRITE
        ) >= 0 else {
            throw EmbeddedSubtitleMuxError.cannotCreateOutput
        }
        let headerStatus = avformat_write_header(output, nil)
        guard headerStatus >= 0 else {
            throw EmbeddedSubtitleMuxError.cannotWriteHeader(
                ffmpegError(headerStatus)
            )
        }

        let scheduledCues = makeSchedule(
            tracks: tracks.filter { !$0.cues.isEmpty },
            outputStreams: subtitleOutputStreams
        )
        var nextSubtitleIndex = 0
        guard let mediaPacket = av_packet_alloc(),
              let subtitlePacket = av_packet_alloc() else {
            throw EmbeddedSubtitleMuxError.cannotCreateOutput
        }
        var mediaPacketToFree: UnsafeMutablePointer<AVPacket>? = mediaPacket
        var subtitlePacketToFree: UnsafeMutablePointer<AVPacket>? = subtitlePacket
        defer {
            av_packet_free(&mediaPacketToFree)
            av_packet_free(&subtitlePacketToFree)
        }

        let durationSeconds = inputDurationSeconds(input)
        var lastProgressUpdate = CFAbsoluteTimeGetCurrent()
        while av_read_frame(input, mediaPacket) >= 0 {
            defer { av_packet_unref(mediaPacket) }
            let inputIndex = mediaPacket.pointee.stream_index
            guard let outputIndex = streamMap[inputIndex],
                  let inputStream = input.pointee.streams[Int(inputIndex)],
                  let outputStream = output.pointee.streams[Int(outputIndex)] else {
                continue
            }

            if let seconds = packetSeconds(
                mediaPacket,
                timeBase: inputStream.pointee.time_base
            ) {
                while nextSubtitleIndex < scheduledCues.count,
                      scheduledCues[nextSubtitleIndex].cue.startTime <= seconds {
                    try writeSubtitlePacket(
                        scheduledCues[nextSubtitleIndex],
                        packet: subtitlePacket,
                        output: output
                    )
                    nextSubtitleIndex += 1
                }
                if durationSeconds > 0,
                   CFAbsoluteTimeGetCurrent() - lastProgressUpdate >= 0.1 {
                    lastProgressUpdate = CFAbsoluteTimeGetCurrent()
                    let value = min(max(seconds / durationSeconds, 0), 1) * 0.98
                    await MainActor.run { progress(value) }
                }
            }

            av_packet_rescale_ts(
                mediaPacket,
                inputStream.pointee.time_base,
                outputStream.pointee.time_base
            )
            mediaPacket.pointee.stream_index = outputIndex
            mediaPacket.pointee.pos = -1
            let packetDescription = "media stream \(inputIndex) → \(outputIndex), "
                + "pts \(mediaPacket.pointee.pts), "
                + "dts \(mediaPacket.pointee.dts), "
                + "duration \(mediaPacket.pointee.duration), "
                + "time base \(outputStream.pointee.time_base.num)/"
                + "\(outputStream.pointee.time_base.den)"
            let status = av_interleaved_write_frame(output, mediaPacket)
            guard status >= 0 else {
                throw EmbeddedSubtitleMuxError.cannotWritePacket(
                    packetDescription + ": " + ffmpegError(status)
                )
            }
        }

        while nextSubtitleIndex < scheduledCues.count {
            try writeSubtitlePacket(
                scheduledCues[nextSubtitleIndex],
                packet: subtitlePacket,
                output: output
            )
            nextSubtitleIndex += 1
        }

        let trailerStatus = av_write_trailer(output)
        guard trailerStatus >= 0 else {
            throw EmbeddedSubtitleMuxError.cannotWritePacket(
                ffmpegError(trailerStatus)
            )
        }
        didFinish = true
        await MainActor.run { progress(1) }
    }

    private struct ScheduledCue {
        let outputStreamIndex: Int32
        let cue: EmbeddedSubtitleCue
    }

    private static func makeSchedule(
        tracks: [EmbeddedSubtitleTrack],
        outputStreams: [UnsafeMutablePointer<AVStream>]
    ) -> [ScheduledCue] {
        zip(tracks, outputStreams)
            .flatMap { track, stream in
                track.cues.map {
                    ScheduledCue(
                        outputStreamIndex: stream.pointee.index,
                        cue: $0
                    )
                }
            }
            .sorted {
                if $0.cue.startTime == $1.cue.startTime {
                    return $0.outputStreamIndex < $1.outputStreamIndex
                }
                return $0.cue.startTime < $1.cue.startTime
            }
    }

    private static func writeSubtitlePacket(
        _ scheduled: ScheduledCue,
        packet: UnsafeMutablePointer<AVPacket>,
        output: UnsafeMutablePointer<AVFormatContext>
    ) throws {
        av_packet_unref(packet)
        let payload = Data(scheduled.cue.text.utf8)
        guard !payload.isEmpty,
              av_new_packet(packet, Int32(payload.count)) >= 0,
              let packetData = packet.pointee.data else {
            return
        }
        _ = payload.copyBytes(
            to: UnsafeMutableBufferPointer(
                start: packetData,
                count: payload.count
            )
        )
        let startMilliseconds = Int64(
            (max(0, scheduled.cue.startTime) * 1_000).rounded()
        )
        let endMilliseconds = Int64(
            (max(scheduled.cue.endTime, scheduled.cue.startTime) * 1_000).rounded()
        )
        packet.pointee.pts = startMilliseconds
        packet.pointee.dts = startMilliseconds
        packet.pointee.duration = max(1, endMilliseconds - startMilliseconds)
        packet.pointee.stream_index = scheduled.outputStreamIndex
        packet.pointee.flags |= AV_PKT_FLAG_KEY
        packet.pointee.pos = -1
        let status = av_interleaved_write_frame(output, packet)
        guard status >= 0 else {
            throw EmbeddedSubtitleMuxError.cannotWritePacket(
                "subtitle stream \(scheduled.outputStreamIndex), "
                    + "pts \(startMilliseconds): "
                    + ffmpegError(status)
            )
        }
    }

    private static func packetSeconds(
        _ packet: UnsafeMutablePointer<AVPacket>,
        timeBase: AVRational
    ) -> Double? {
        let timestamp = packet.pointee.dts != noTimestamp
            ? packet.pointee.dts
            : packet.pointee.pts
        guard timestamp != noTimestamp, timeBase.den != 0 else {
            return nil
        }
        let seconds = Double(timestamp)
            * Double(timeBase.num)
            / Double(timeBase.den)
        return seconds.isFinite ? seconds : nil
    }

    private static func inputDurationSeconds(
        _ input: UnsafeMutablePointer<AVFormatContext>
    ) -> Double {
        guard input.pointee.duration != noTimestamp,
              input.pointee.duration > 0 else {
            return 0
        }
        return Double(input.pointee.duration) / Double(AV_TIME_BASE)
    }

    private static func ffmpegError(_ status: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(status, &buffer, buffer.count)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

@MainActor
final class EmbeddedSubtitleExportCoordinator: ObservableObject {
    @Published private(set) var progress: Double?
    @Published private(set) var completionMessage: String?

    private var task: Task<Void, Never>?

    func start(project: SubtitleProject, destinationURL: URL) {
        guard task == nil, progress == nil else { return }
        guard let videoURL = project.videoURL else {
            completionMessage = HardSubtitleVideoExportError.missingMedia.localizedDescription
            return
        }
        let sourceURL = project.mediaAccessStatus.resolvedURL
            ?? project.resolveOriginalURL(videoURL)
        let tracks = EmbeddedSubtitleTrackBuilder.tracks(for: project)

        progress = 0
        completionMessage = nil
        task = Task { [self] in
            defer {
                progress = nil
                task = nil
            }
            do {
                try await EmbeddedSubtitleMediaMuxer.mux(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    tracks: tracks
                ) { [weak self] value in
                    self?.progress = value
                }
                completionMessage = String.localizedStringWithFormat(
                    String(localized: "export_completed_format %@"),
                    destinationURL.lastPathComponent
                )
            } catch {
                completionMessage = error.localizedDescription
            }
        }
    }

    func clearCompletionMessage() {
        completionMessage = nil
    }
}
