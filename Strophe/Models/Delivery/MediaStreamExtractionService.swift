import Foundation
import Libavcodec
import Libavformat
import Libavutil

enum MediaStreamExtractionError: LocalizedError {
    case cannotOpenInput
    case cannotReadStreams
    case streamNotFound(Int)
    case unsupportedStream
    case cannotCreateOutput
    case cannotWriteOutput(String)
    case emptyAttachment

    var errorDescription: String? {
        switch self {
        case .cannotOpenInput:
            return String(localized: "media_extract_cannot_open")
        case .cannotReadStreams:
            return String(localized: "media_extract_cannot_read_streams")
        case .streamNotFound(let index):
            return String.localizedStringWithFormat(
                String(localized: "media_extract_stream_missing_format"),
                index
            )
        case .unsupportedStream:
            return String(localized: "media_extract_unsupported")
        case .cannotCreateOutput:
            return String(localized: "media_extract_cannot_create_output")
        case .cannotWriteOutput(let detail):
            return String.localizedStringWithFormat(
                String(localized: "media_extract_write_failed_format"),
                detail
            )
        case .emptyAttachment:
            return String(localized: "media_extract_empty_attachment")
        }
    }
}

/// Packet-copy extraction keeps the original audio/subtitle codec intact and
/// avoids a generation loss. Attachments are copied from FFmpeg extradata.
nonisolated enum MediaStreamExtractionService {
    static func extract(
        stream: MediaStreamInformation,
        from sourceURL: URL,
        to destinationURL: URL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let inputAccess = sourceURL.startAccessingSecurityScopedResource()
            let outputAccess = destinationURL.startAccessingSecurityScopedResource()
            defer {
                if inputAccess { sourceURL.stopAccessingSecurityScopedResource() }
                if outputAccess { destinationURL.stopAccessingSecurityScopedResource() }
            }

            switch stream.kind {
            case .audio, .subtitle:
                try remuxStream(
                    index: stream.id,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL
                )
            case .attachment:
                try extractAttachment(
                    index: stream.id,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL
                )
            case .video, .data, .unknown:
                throw MediaStreamExtractionError.unsupportedStream
            }
        }.value
    }

    private static func openInput(
        _ sourceURL: URL
    ) throws -> UnsafeMutablePointer<AVFormatContext> {
        var context: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&context, sourceURL.resolvingSymlinksInPath().path, nil, nil) >= 0,
              let context else {
            throw MediaStreamExtractionError.cannotOpenInput
        }
        guard avformat_find_stream_info(context, nil) >= 0 else {
            var value: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&value)
            throw MediaStreamExtractionError.cannotReadStreams
        }
        return context
    }

    private static func remuxStream(
        index: Int,
        sourceURL: URL,
        destinationURL: URL
    ) throws {
        var input: UnsafeMutablePointer<AVFormatContext>? = try openInput(sourceURL)
        defer { avformat_close_input(&input) }
        guard let input,
              index >= 0,
              index < Int(input.pointee.nb_streams),
              let inputStream = input.pointee.streams[index],
              let inputParameters = inputStream.pointee.codecpar else {
            throw MediaStreamExtractionError.streamNotFound(index)
        }

        let mediaType = inputParameters.pointee.codec_type
        guard mediaType == AVMEDIA_TYPE_AUDIO || mediaType == AVMEDIA_TYPE_SUBTITLE else {
            throw MediaStreamExtractionError.unsupportedStream
        }

        try? FileManager.default.removeItem(at: destinationURL)
        var output: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(
            &output,
            nil,
            nil,
            destinationURL.path
        ) >= 0, let output else {
            throw MediaStreamExtractionError.cannotCreateOutput
        }
        defer {
            if output.pointee.pb != nil {
                avio_closep(&output.pointee.pb)
            }
            avformat_free_context(output)
        }

        guard let outputStream = avformat_new_stream(output, nil),
              let outputParameters = outputStream.pointee.codecpar,
              avcodec_parameters_copy(outputParameters, inputParameters) >= 0 else {
            throw MediaStreamExtractionError.cannotCreateOutput
        }
        outputParameters.pointee.codec_tag = 0
        outputStream.pointee.time_base = inputStream.pointee.time_base
        av_dict_copy(&outputStream.pointee.metadata, inputStream.pointee.metadata, 0)

        guard avio_open(&output.pointee.pb, destinationURL.path, AVIO_FLAG_WRITE) >= 0 else {
            throw MediaStreamExtractionError.cannotCreateOutput
        }
        guard avformat_write_header(output, nil) >= 0 else {
            throw MediaStreamExtractionError.cannotCreateOutput
        }

        guard let packet = av_packet_alloc() else {
            throw MediaStreamExtractionError.cannotCreateOutput
        }
        var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetToFree) }

        while av_read_frame(input, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == Int32(index) else { continue }
            av_packet_rescale_ts(
                packet,
                inputStream.pointee.time_base,
                outputStream.pointee.time_base
            )
            packet.pointee.stream_index = 0
            packet.pointee.pos = -1
            let status = av_interleaved_write_frame(output, packet)
            guard status >= 0 else {
                throw MediaStreamExtractionError.cannotWriteOutput(ffmpegError(status))
            }
        }

        let trailerStatus = av_write_trailer(output)
        guard trailerStatus >= 0 else {
            throw MediaStreamExtractionError.cannotWriteOutput(ffmpegError(trailerStatus))
        }
    }

    private static func extractAttachment(
        index: Int,
        sourceURL: URL,
        destinationURL: URL
    ) throws {
        var input: UnsafeMutablePointer<AVFormatContext>? = try openInput(sourceURL)
        defer { avformat_close_input(&input) }
        guard let input,
              index >= 0,
              index < Int(input.pointee.nb_streams),
              let stream = input.pointee.streams[index],
              let parameters = stream.pointee.codecpar else {
            throw MediaStreamExtractionError.streamNotFound(index)
        }
        guard parameters.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT else {
            throw MediaStreamExtractionError.unsupportedStream
        }
        guard let bytes = parameters.pointee.extradata,
              parameters.pointee.extradata_size > 0 else {
            throw MediaStreamExtractionError.emptyAttachment
        }
        let data = Data(bytes: bytes, count: Int(parameters.pointee.extradata_size))
        try data.write(to: destinationURL, options: .atomic)
    }

    private static func ffmpegError(_ status: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(status, &buffer, buffer.count)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
