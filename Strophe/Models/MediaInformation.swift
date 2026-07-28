import Foundation
import Libavcodec
import Libavformat
import Libavutil

nonisolated struct MediaInformationField: Identifiable, Sendable {
    let id: String
    let labelKey: String
    let value: String

    nonisolated init(_ id: String, labelKey: String? = nil, value: String) {
        self.id = id
        self.labelKey = labelKey ?? id
        self.value = value
    }
}

nonisolated struct MediaStreamInformation: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case video
        case audio
        case subtitle
        case data
        case attachment
        case unknown

        nonisolated var iconName: String {
            switch self {
            case .video: return "film"
            case .audio: return "waveform"
            case .subtitle: return "captions.bubble"
            case .data: return "chart.bar.doc.horizontal"
            case .attachment: return "paperclip"
            case .unknown: return "questionmark.circle"
            }
        }

        nonisolated var localizedNameKey: String {
            switch self {
            case .video: return "media_stream_video"
            case .audio: return "media_stream_audio"
            case .subtitle: return "media_stream_subtitle"
            case .data: return "media_stream_data"
            case .attachment: return "media_stream_attachment"
            case .unknown: return "media_stream_unknown"
            }
        }
    }

    let id: Int
    let kind: Kind
    let codecName: String
    let fields: [MediaInformationField]

    nonisolated init(id: Int, kind: Kind, codecName: String, fields: [MediaInformationField]) {
        self.id = id
        self.kind = kind
        self.codecName = codecName
        self.fields = fields
    }

    nonisolated var extractionFileExtension: String? {
        let codec = codecName.lowercased()
        switch kind {
        case .audio:
            if codec.contains("aac") || codec.contains("alac") { return "m4a" }
            if codec.contains("mp3") { return "mp3" }
            if codec.contains("flac") { return "flac" }
            if codec.contains("opus") || codec.contains("vorbis") { return "ogg" }
            if codec.contains("pcm") { return "wav" }
            return "mka"
        case .subtitle:
            // MOV text packets are container-specific. Keeping them in a small
            // MP4 preserves the stream without a lossy decode/re-encode step.
            if codec.contains("mov_text") { return "mp4" }
            if codec.contains("ass") || codec.contains("ssa") { return "ass" }
            if codec.contains("subrip") || codec == "srt" { return "srt" }
            if codec.contains("webvtt") { return "vtt" }
            return "mks"
        case .attachment:
            if let fileName = attachmentFileName,
               !URL(fileURLWithPath: fileName).pathExtension.isEmpty {
                return URL(fileURLWithPath: fileName).pathExtension
            }
            return "bin"
        case .video, .data, .unknown:
            return nil
        }
    }

    nonisolated var extractionSuggestedFileName: String? {
        guard let pathExtension = extractionFileExtension else { return nil }
        if kind == .attachment, let attachmentFileName {
            return attachmentFileName
        }
        let kindName: String
        switch kind {
        case .audio: kindName = "audio"
        case .subtitle: kindName = "subtitle"
        case .attachment: kindName = "attachment"
        default: kindName = "stream"
        }
        return "\(kindName)-\(id).\(pathExtension)"
    }

    private nonisolated var attachmentFileName: String? {
        fields.first {
            $0.id.lowercased().contains("filename")
                || $0.labelKey.lowercased() == "filename"
        }?.value
    }
}

nonisolated struct MediaInformationSnapshot: Sendable {
    let sourceURL: URL
    let displayName: String
    let formatSummary: String
    let duration: Double?
    let fileFields: [MediaInformationField]
    let streams: [MediaStreamInformation]

    nonisolated init(
        sourceURL: URL,
        displayName: String,
        formatSummary: String,
        duration: Double?,
        fileFields: [MediaInformationField],
        streams: [MediaStreamInformation]
    ) {
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.formatSummary = formatSummary
        self.duration = duration
        self.fileFields = fileFields
        self.streams = streams
    }

    nonisolated var videoStreamCount: Int {
        streams.lazy.filter { $0.kind == .video }.count
    }

    nonisolated var audioStreamCount: Int {
        streams.lazy.filter { $0.kind == .audio }.count
    }
}

nonisolated enum MediaInformationProbeError: LocalizedError {
    case cannotOpen
    case cannotReadStreams

    var errorDescription: String? {
        switch self {
        case .cannotOpen:
            return String(localized: "media_info_error_open")
        case .cannotReadStreams:
            return String(localized: "media_info_error_streams")
        }
    }
}

nonisolated enum MediaInformationProbe {
    nonisolated private static let noTimestamp = Int64(bitPattern: 0x8000000000000000)

    static func load(from sourceURL: URL) async throws -> MediaInformationSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try probe(sourceURL: sourceURL)
        }.value
    }

    private nonisolated static func probe(sourceURL: URL) throws -> MediaInformationSnapshot {
        let didStartSecurityScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let resolvedURL = sourceURL.resolvingSymlinksInPath()
        var formatContext: UnsafeMutablePointer<AVFormatContext>?

        guard avformat_open_input(&formatContext, resolvedURL.path, nil, nil) >= 0,
              let formatContext else {
            print("❌ Media information probe could not open: \(resolvedURL.path)")
            throw MediaInformationProbeError.cannotOpen
        }
        defer {
            var context: UnsafeMutablePointer<AVFormatContext>? = formatContext
            avformat_close_input(&context)
        }

        guard avformat_find_stream_info(formatContext, nil) >= 0 else {
            print("❌ Media information probe could not read streams: \(resolvedURL.path)")
            throw MediaInformationProbeError.cannotReadStreams
        }

        let context = formatContext.pointee
        let inputFormat = context.iformat?.pointee
        let shortFormatName = inputFormat.flatMap { string($0.name) } ?? sourceURL.pathExtension.uppercased()
        let longFormatName = inputFormat.flatMap { string($0.long_name) }
        let formatSummary = longFormatName ?? shortFormatName
        let duration = seconds(context.duration, timeBase: Double(AV_TIME_BASE))

        var fileFields: [MediaInformationField] = [
            .init("file_name", labelKey: "media_info_file_name", value: resolvedURL.lastPathComponent),
            .init("file_path", labelKey: "media_info_file_path", value: resolvedURL.path),
            .init("format", labelKey: "media_info_format", value: joinedUnique([shortFormatName, longFormatName])),
            .init("stream_count", labelKey: "media_info_stream_count", value: String(context.nb_streams))
        ]

        if let duration {
            fileFields.append(.init("duration", labelKey: "media_info_duration", value: formattedDuration(duration)))
        }
        if let startTime = seconds(context.start_time, timeBase: Double(AV_TIME_BASE)) {
            fileFields.append(.init("start_time", labelKey: "media_info_start_time", value: formattedDuration(startTime)))
        }
        if context.bit_rate > 0 {
            fileFields.append(.init("bit_rate", labelKey: "media_info_bit_rate", value: formattedBitRate(context.bit_rate)))
        }
        if context.probe_score > 0 {
            fileFields.append(.init("probe_score", labelKey: "media_info_probe_score", value: String(context.probe_score)))
        }
        if let fileSize = try? resolvedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            fileFields.append(.init("file_size", labelKey: "media_info_file_size", value: formattedByteCount(Int64(fileSize))))
        }
        fileFields.append(contentsOf: metadataFields(context.metadata, prefix: "file_tag"))

        var streams: [MediaStreamInformation] = []
        streams.reserveCapacity(Int(context.nb_streams))
        for streamIndex in 0..<context.nb_streams {
            guard let streamPointer = context.streams[Int(streamIndex)],
                  let parametersPointer = streamPointer.pointee.codecpar else {
                continue
            }
            streams.append(
                makeStreamInformation(
                    index: Int(streamIndex),
                    stream: streamPointer.pointee,
                    parameters: parametersPointer.pointee
                )
            )
        }

        let snapshot = MediaInformationSnapshot(
            sourceURL: resolvedURL,
            displayName: resolvedURL.lastPathComponent,
            formatSummary: formatSummary,
            duration: duration,
            fileFields: fileFields,
            streams: streams
        )
        print("ℹ️ Media information probe: \(resolvedURL.lastPathComponent), \(streams.count) stream(s)")
        return snapshot
    }

    private nonisolated static func makeStreamInformation(
        index: Int,
        stream: AVStream,
        parameters: AVCodecParameters
    ) -> MediaStreamInformation {
        let kind = streamKind(parameters.codec_type)
        let codecName = string(avcodec_get_name(parameters.codec_id)) ?? "—"
        var fields: [MediaInformationField] = [
            .init("index", labelKey: "media_info_index", value: String(index)),
            .init("stream_id", labelKey: "media_info_stream_id", value: String(stream.id)),
            .init("type", labelKey: "media_info_type", value: rawMediaTypeName(parameters.codec_type)),
            .init("codec", labelKey: "media_info_codec", value: codecDescription(parameters.codec_id, fallback: codecName))
        ]

        if let profile = string(avcodec_profile_name(parameters.codec_id, parameters.profile)) {
            fields.append(.init("profile", labelKey: "media_info_profile", value: profile))
        }
        if parameters.level > 0 {
            fields.append(.init("level", labelKey: "media_info_level", value: String(parameters.level)))
        }
        if parameters.bit_rate > 0 {
            fields.append(.init("bit_rate", labelKey: "media_info_bit_rate", value: formattedBitRate(parameters.bit_rate)))
        }

        switch kind {
        case .video:
            if parameters.width > 0, parameters.height > 0 {
                fields.append(
                    .init(
                        "resolution",
                        labelKey: "media_info_resolution",
                        value: "\(parameters.width) × \(parameters.height)"
                    )
                )
            }
            if parameters.format >= 0,
               let pixelFormat = string(av_get_pix_fmt_name(AVPixelFormat(rawValue: parameters.format))) {
                fields.append(.init("pixel_format", labelKey: "media_info_pixel_format", value: pixelFormat))
            }
            if let frameRate = rationalValue(stream.avg_frame_rate), frameRate > 0 {
                fields.append(
                    .init(
                        "frame_rate",
                        labelKey: "media_info_frame_rate",
                        value: String(format: "%.3f fps", frameRate)
                    )
                )
            }
            if let aspectRatio = rationalValue(parameters.sample_aspect_ratio), aspectRatio > 0 {
                fields.append(
                    .init(
                        "sample_aspect_ratio",
                        labelKey: "media_info_sample_aspect_ratio",
                        value: rationalDescription(parameters.sample_aspect_ratio)
                    )
                )
            }
            if parameters.video_delay > 0 {
                fields.append(.init("video_delay", labelKey: "media_info_video_delay", value: String(parameters.video_delay)))
            }
            let colorDescription = joinedUnique([
                string(av_color_primaries_name(parameters.color_primaries)),
                string(av_color_transfer_name(parameters.color_trc)),
                string(av_color_space_name(parameters.color_space))
            ])
            if !colorDescription.isEmpty {
                fields.append(.init("color", labelKey: "media_info_color", value: colorDescription))
            }
        case .audio:
            if parameters.sample_rate > 0 {
                fields.append(
                    .init(
                        "sample_rate",
                        labelKey: "media_info_sample_rate",
                        value: "\(parameters.sample_rate) Hz"
                    )
                )
            }
            if parameters.ch_layout.nb_channels > 0 {
                fields.append(
                    .init(
                        "channels",
                        labelKey: "media_info_channels",
                        value: channelLayoutDescription(parameters.ch_layout)
                    )
                )
            }
            if parameters.format >= 0,
               let sampleFormat = string(av_get_sample_fmt_name(AVSampleFormat(rawValue: parameters.format))) {
                fields.append(.init("sample_format", labelKey: "media_info_sample_format", value: sampleFormat))
            }
            if parameters.bits_per_raw_sample > 0 {
                fields.append(
                    .init(
                        "bits_per_sample",
                        labelKey: "media_info_bits_per_sample",
                        value: String(parameters.bits_per_raw_sample)
                    )
                )
            }
            if parameters.frame_size > 0 {
                fields.append(.init("frame_size", labelKey: "media_info_frame_size", value: String(parameters.frame_size)))
            }
        default:
            break
        }

        if let streamDuration = seconds(stream.duration, rational: stream.time_base) {
            fields.append(.init("duration", labelKey: "media_info_duration", value: formattedDuration(streamDuration)))
        }
        if let streamStartTime = seconds(stream.start_time, rational: stream.time_base) {
            fields.append(.init("start_time", labelKey: "media_info_start_time", value: formattedDuration(streamStartTime)))
        }
        if stream.time_base.den != 0 {
            fields.append(.init("time_base", labelKey: "media_info_time_base", value: rationalDescription(stream.time_base)))
        }
        if stream.nb_frames > 0 {
            fields.append(.init("frame_count", labelKey: "media_info_frame_count", value: String(stream.nb_frames)))
        }

        let disposition = dispositionDescription(stream.disposition)
        if !disposition.isEmpty {
            fields.append(.init("disposition", labelKey: "media_info_disposition", value: disposition))
        }
        fields.append(contentsOf: metadataFields(stream.metadata, prefix: "stream_\(index)_tag"))

        return MediaStreamInformation(
            id: index,
            kind: kind,
            codecName: codecName,
            fields: fields
        )
    }

    private nonisolated static func streamKind(_ type: AVMediaType) -> MediaStreamInformation.Kind {
        switch type {
        case AVMEDIA_TYPE_VIDEO: return .video
        case AVMEDIA_TYPE_AUDIO: return .audio
        case AVMEDIA_TYPE_SUBTITLE: return .subtitle
        case AVMEDIA_TYPE_DATA: return .data
        case AVMEDIA_TYPE_ATTACHMENT: return .attachment
        default: return .unknown
        }
    }

    private nonisolated static func rawMediaTypeName(_ type: AVMediaType) -> String {
        string(av_get_media_type_string(type)) ?? "unknown"
    }

    private nonisolated static func codecDescription(_ codecID: AVCodecID, fallback: String) -> String {
        guard let descriptor = avcodec_descriptor_get(codecID),
              let longName = string(descriptor.pointee.long_name),
              longName.caseInsensitiveCompare(fallback) != .orderedSame else {
            return fallback
        }
        return "\(fallback) — \(longName)"
    }

    private nonisolated static func metadataFields(
        _ dictionary: OpaquePointer?,
        prefix: String
    ) -> [MediaInformationField] {
        var fields: [MediaInformationField] = []
        var previous: UnsafeMutablePointer<AVDictionaryEntry>?
        while let entry = av_dict_get(dictionary, "", previous, AV_DICT_IGNORE_SUFFIX) {
            guard let key = string(entry.pointee.key),
                  let value = string(entry.pointee.value),
                  !key.isEmpty,
                  !value.isEmpty else {
                previous = entry
                continue
            }
            fields.append(
                .init(
                    "\(prefix)_\(key)_\(fields.count)",
                    labelKey: key.replacingOccurrences(of: "_", with: " ").capitalized,
                    value: value
                )
            )
            previous = entry
        }
        return fields
    }

    private nonisolated static func dispositionDescription(_ disposition: Int32) -> String {
        var values: [String] = []
        if disposition & AV_DISPOSITION_DEFAULT != 0 { values.append("default") }
        if disposition & AV_DISPOSITION_FORCED != 0 { values.append("forced") }
        if disposition & AV_DISPOSITION_HEARING_IMPAIRED != 0 { values.append("hearing impaired") }
        if disposition & AV_DISPOSITION_VISUAL_IMPAIRED != 0 { values.append("visual impaired") }
        if disposition & AV_DISPOSITION_ATTACHED_PIC != 0 { values.append("attached picture") }
        return values.joined(separator: ", ")
    }

    private nonisolated static func channelLayoutDescription(_ layout: AVChannelLayout) -> String {
        var layout = layout
        var buffer = [CChar](repeating: 0, count: 128)
        let result = av_channel_layout_describe(&layout, &buffer, buffer.count)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let description = result >= 0 ? String(decoding: bytes, as: UTF8.self) : ""
        if description.isEmpty {
            return String(layout.nb_channels)
        }
        return "\(layout.nb_channels) (\(description))"
    }

    private nonisolated static func seconds(_ timestamp: Int64, timeBase: Double) -> Double? {
        guard timestamp != noTimestamp, timeBase > 0 else { return nil }
        let value = Double(timestamp) / timeBase
        return value.isFinite ? value : nil
    }

    private nonisolated static func seconds(_ timestamp: Int64, rational: AVRational) -> Double? {
        guard timestamp != noTimestamp, rational.den != 0 else { return nil }
        let value = Double(timestamp) * Double(rational.num) / Double(rational.den)
        return value.isFinite ? value : nil
    }

    private nonisolated static func rationalValue(_ rational: AVRational) -> Double? {
        guard rational.den != 0 else { return nil }
        let value = Double(rational.num) / Double(rational.den)
        return value.isFinite ? value : nil
    }

    private nonisolated static func rationalDescription(_ rational: AVRational) -> String {
        rational.den == 0 ? "—" : "\(rational.num):\(rational.den)"
    }

    private nonisolated static func formattedDuration(_ duration: Double) -> String {
        let totalMilliseconds = Int64((duration * 1_000).rounded())
        let milliseconds = abs(totalMilliseconds % 1_000)
        let totalSeconds = abs(totalMilliseconds / 1_000)
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3_600
        let sign = totalMilliseconds < 0 ? "−" : ""
        return String(format: "%@%02lld:%02lld:%02lld.%03lld", sign, hours, minutes, seconds, milliseconds)
    }

    private nonisolated static func formattedBitRate(_ bitRate: Int64) -> String {
        let value = Double(bitRate)
        if value >= 1_000_000_000 {
            return String(format: "%.2f Gbit/s", value / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.2f Mbit/s", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1f kbit/s", value / 1_000)
        }
        return "\(bitRate) bit/s"
    }

    private nonisolated static func formattedByteCount(_ byteCount: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: byteCount)
    }

    private nonisolated static func joinedUnique(_ values: [String?]) -> String {
        var seen: Set<String> = []
        return values.compactMap { $0 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: " — ")
    }

    private nonisolated static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        var count = 0
        while pointer[count] != 0 {
            count += 1
        }
        let bytes = UnsafeBufferPointer(start: pointer, count: count)
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
