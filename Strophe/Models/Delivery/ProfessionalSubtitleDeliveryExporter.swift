import Foundation

nonisolated enum ProfessionalSubtitleDeliveryError: LocalizedError {
    case noTimedSubtitles
    case cannotRenderGraphics(String)
    case cannotEncodePNG
    case cannotCreateClosedCaptionOutput(String)
    case cannotWriteClosedCaptionHeader(String)
    case cannotWriteClosedCaptionPacket(String)

    var errorDescription: String? {
        switch self {
        case .noTimedSubtitles:
            return String(localized: "professional_export_no_timed_subtitles")
        case let .cannotRenderGraphics(text):
            return String(
                format: String(localized: "professional_export_render_failed_format"),
                text
            )
        case .cannotEncodePNG:
            return String(localized: "professional_export_png_failed")
        case let .cannotCreateClosedCaptionOutput(message):
            return String(
                format: String(localized: "professional_export_create_failed_format"),
                message
            )
        case let .cannotWriteClosedCaptionHeader(message):
            return String(
                format: String(localized: "professional_export_header_failed_format"),
                message
            )
        case let .cannotWriteClosedCaptionPacket(message):
            return String(
                format: String(localized: "professional_export_write_failed_format"),
                message
            )
        }
    }
}

nonisolated enum TTMLDeliveryProfile: Sendable {
    case ttml
    case imsc1
}

nonisolated enum ClosedCaptionSidecarFormat: String, Sendable {
    case scc
    case mcc
}

nonisolated struct ProfessionalTimedCue: Sendable, Equatable {
    var id: UUID
    var startTime: Double
    var endTime: Double
    var text: String
    var languageCode: String?
}

enum ProfessionalSubtitleDeliveryExporter {
    @MainActor
    static func ttml(
        project: SubtitleProject,
        profile: TTMLDeliveryProfile
    ) throws -> Data {
        let cues = timedCues(project: project)
        guard !cues.isEmpty else {
            throw ProfessionalSubtitleDeliveryError.noTimedSubtitles
        }
        return TTMLSidecarEncoder.encode(
            cues: cues,
            profile: profile,
            canvasSize: resolvedCanvasSize(project.videoSize)
        )
    }

    @MainActor
    static func avidDS(project: SubtitleProject) throws -> Data {
        let cues = timedCues(project: project)
        guard !cues.isEmpty else {
            throw ProfessionalSubtitleDeliveryError.noTimedSubtitles
        }
        return AvidDSCaptionEncoder.encode(
            cues: cues,
            frameRate: ProfessionalFrameRate.nearest(to: project.videoFrameRate)
        )
    }

    @MainActor
    static func closedCaption(
        project: SubtitleProject,
        format: ClosedCaptionSidecarFormat
    ) throws -> Data {
        let cues = timedCues(project: project)
        guard !cues.isEmpty else {
            throw ProfessionalSubtitleDeliveryError.noTimedSubtitles
        }
        let frameRate: ProfessionalFrameRate
        switch format {
        case .scc:
            // Scenarist SCC is a CEA-608 interchange format whose de-facto
            // timing base is NTSC 29.97 drop-frame.
            frameRate = .ntsc2997
        case .mcc:
            frameRate = .nearest(to: project.videoFrameRate)
        }
        return try CEA608SidecarEncoder.encode(
            cues: cues,
            format: format,
            frameRate: frameRate
        )
    }

    @MainActor
    static func ebuSTL(project: SubtitleProject) throws -> Data {
        let cues = timedCues(project: project)
        guard !cues.isEmpty else {
            throw ProfessionalSubtitleDeliveryError.noTimedSubtitles
        }
        let frameRate: Int = project.videoFrameRate < 27.5 ? 25 : 30
        return EBUSTLEncoder.encode(
            cues: cues,
            frameRate: frameRate,
            programmeTitle: project.documentDisplayName
        )
    }

    @MainActor
    static func timedCues(project: SubtitleProject) -> [ProfessionalTimedCue] {
        let store = StyleAndGroupStore.shared
        return project.items.compactMap { item in
            guard let start = item.startTime,
                  let end = item.endTime,
                  start.isFinite,
                  end.isFinite,
                  end > start,
                  !item.isHidden,
                  !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            if let group = store.group(id: item.groupID) {
                switch group.exportPolicy {
                case .includeInAllExports, .textOnly:
                    break
                case .burnedInOnly, .excludeByDefault, .referenceOnly:
                    return nil
                }
            }
            let clampedStart = max(0, start)
            let clampedEnd = max(0, end)
            guard clampedEnd > clampedStart else { return nil }
            return ProfessionalTimedCue(
                id: item.id,
                startTime: clampedStart,
                endTime: clampedEnd,
                text: item.text,
                languageCode: item.languageCode
            )
        }
        .sorted {
            if $0.startTime == $1.startTime {
                return $0.endTime < $1.endTime
            }
            return $0.startTime < $1.startTime
        }
    }

    static func resolvedCanvasSize(_ rawSize: CGSize) -> CGSize {
        guard rawSize.width.isFinite,
              rawSize.height.isFinite,
              rawSize.width >= 16,
              rawSize.height >= 16 else {
            return CGSize(width: 1_920, height: 1_080)
        }
        return CGSize(
            width: rawSize.width.rounded(),
            height: rawSize.height.rounded()
        )
    }
}

// MARK: - TTML / IMSC

nonisolated private enum TTMLSidecarEncoder {
    static func encode(
        cues: [ProfessionalTimedCue],
        profile: TTMLDeliveryProfile,
        canvasSize: CGSize
    ) -> Data {
        let language = xmlLanguage(
            cues.compactMap(\.languageCode).first
        )
        let profileAttribute: String
        let metadata: String
        switch profile {
        case .ttml:
            profileAttribute = #"ttp:timeBase="media""#
            metadata = """
                  <metadata>
                    <ttm:title>Strophe Timed Text</ttm:title>
                  </metadata>
            """
        case .imsc1:
            profileAttribute = """
            ttp:timeBase="media" ttp:contentProfiles="http://www.w3.org/ns/ttml/profile/imsc1.2/text"
            """
            metadata = """
                  <metadata>
                    <ttm:title>Strophe IMSC 1.2 Text</ttm:title>
                  </metadata>
            """
        }

        let paragraphs = cues.enumerated().map { index, cue in
            let text = ttmlText(cue.text)
            return """
                    <p xml:id="cue\(index + 1)" begin="\(clock(cue.startTime))" end="\(clock(cue.endTime))" style="defaultStyle">\(text)</p>
            """
        }
        .joined(separator: "\n")

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml"
            xmlns:tts="http://www.w3.org/ns/ttml#styling"
            xmlns:ttp="http://www.w3.org/ns/ttml#parameter"
            xmlns:ttm="http://www.w3.org/ns/ttml#metadata"
            xml:lang="\(language)"
            \(profileAttribute)
            tts:extent="\(Int(canvasSize.width))px \(Int(canvasSize.height))px">
          <head>
        \(metadata)
            <styling>
              <style xml:id="defaultStyle"
                     tts:fontFamily="proportionalSansSerif"
                     tts:fontSize="100%"
                     tts:color="white"
                     tts:backgroundColor="transparent"
                     tts:textAlign="center"
                     tts:lineHeight="normal"/>
            </styling>
            <layout>
              <region xml:id="bottom"
                      tts:origin="5% 75%"
                      tts:extent="90% 20%"
                      tts:displayAlign="after"
                      tts:overflow="hidden"/>
            </layout>
          </head>
          <body region="bottom">
            <div>
        \(paragraphs)
            </div>
          </body>
        </tt>
        """
        return Data(xml.utf8)
    }

    private static func clock(_ seconds: Double) -> String {
        let milliseconds = Int64((max(0, seconds) * 1_000).rounded())
        return String(
            format: "%02lld:%02lld:%02lld.%03lld",
            milliseconds / 3_600_000,
            (milliseconds / 60_000) % 60,
            (milliseconds / 1_000) % 60,
            milliseconds % 1_000
        )
    }

    private static func xmlLanguage(_ value: String?) -> String {
        let trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        return trimmed?.isEmpty == false ? xmlEscape(trimmed!) : "und"
    }

    private static func ttmlText(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(xmlEscape)
            .joined(separator: "<br/>")
    }

    private static func xmlEscape<S: StringProtocol>(_ value: S) -> String {
        String(value)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - Professional frame time

nonisolated struct ProfessionalFrameRate: Sendable, Equatable {
    var numerator: Int32
    var denominator: Int32
    var nominalFramesPerSecond: Int
    var isDropFrame: Bool

    static let fps24 = ProfessionalFrameRate(
        numerator: 24,
        denominator: 1,
        nominalFramesPerSecond: 24,
        isDropFrame: false
    )
    static let fps25 = ProfessionalFrameRate(
        numerator: 25,
        denominator: 1,
        nominalFramesPerSecond: 25,
        isDropFrame: false
    )
    static let ntsc2997 = ProfessionalFrameRate(
        numerator: 30_000,
        denominator: 1_001,
        nominalFramesPerSecond: 30,
        isDropFrame: true
    )
    static let fps30 = ProfessionalFrameRate(
        numerator: 30,
        denominator: 1,
        nominalFramesPerSecond: 30,
        isDropFrame: false
    )
    static let fps50 = ProfessionalFrameRate(
        numerator: 50,
        denominator: 1,
        nominalFramesPerSecond: 50,
        isDropFrame: false
    )
    static let ntsc5994 = ProfessionalFrameRate(
        numerator: 60_000,
        denominator: 1_001,
        nominalFramesPerSecond: 60,
        isDropFrame: true
    )
    static let fps60 = ProfessionalFrameRate(
        numerator: 60,
        denominator: 1,
        nominalFramesPerSecond: 60,
        isDropFrame: false
    )

    var value: Double {
        Double(numerator) / Double(denominator)
    }

    static func nearest(to rawValue: Double) -> ProfessionalFrameRate {
        let requested = rawValue.isFinite && rawValue > 0 ? rawValue : 30
        return [fps24, fps25, ntsc2997, fps30, fps50, ntsc5994, fps60]
            .min { abs($0.value - requested) < abs($1.value - requested) }
            ?? .fps30
    }

    func frameIndex(for seconds: Double) -> Int64 {
        Int64((max(0, seconds) * value).rounded())
    }

    func timecode(forFrame rawFrame: Int64) -> String {
        var frame = max(0, rawFrame)
        let separator = isDropFrame ? ";" : ":"

        if isDropFrame && nominalFramesPerSecond == 30 {
            let dropFrames: Int64 = 2
            let framesPer10Minutes: Int64 = 17_982
            let framesPerMinute: Int64 = 1_798
            let tenMinuteChunks = frame / framesPer10Minutes
            let remainder = frame % framesPer10Minutes
            frame += dropFrames * 9 * tenMinuteChunks
            if remainder >= dropFrames {
                frame += dropFrames * ((remainder - dropFrames) / framesPerMinute)
            }
        } else if isDropFrame && nominalFramesPerSecond == 60 {
            let dropFrames: Int64 = 4
            let framesPer10Minutes: Int64 = 35_964
            let framesPerMinute: Int64 = 3_596
            let tenMinuteChunks = frame / framesPer10Minutes
            let remainder = frame % framesPer10Minutes
            frame += dropFrames * 9 * tenMinuteChunks
            if remainder >= dropFrames {
                frame += dropFrames * ((remainder - dropFrames) / framesPerMinute)
            }
        }

        let fps = Int64(nominalFramesPerSecond)
        let frames = frame % fps
        let totalSeconds = frame / fps
        return String(
            format: "%02lld:%02lld:%02lld%@%02lld",
            (totalSeconds / 3_600) % 24,
            (totalSeconds / 60) % 60,
            totalSeconds % 60,
            separator,
            frames
        )
    }
}

// MARK: - Avid DS Caption

nonisolated private enum AvidDSCaptionEncoder {
    static func encode(
        cues: [ProfessionalTimedCue],
        frameRate: ProfessionalFrameRate
    ) -> Data {
        let body = cues.map { cue in
            let start = frameRate.timecode(
                forFrame: frameRate.frameIndex(for: cue.startTime)
            )
            let end = frameRate.timecode(
                forFrame: frameRate.frameIndex(for: cue.endTime)
            )
            let normalizedText = cue.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            return "\(start) \(end)\r\n\(normalizedText)"
        }
        .joined(separator: "\r\n\r\n")
        // Avid SubCap accepts Unicode caption files; the UTF-8 BOM also keeps
        // CJK text unambiguous when opened by older versions.
        return Data([0xEF, 0xBB, 0xBF])
            + Data((body + (body.isEmpty ? "" : "\r\n")).utf8)
    }
}

// MARK: - CEA-608 to SCC / MCC

nonisolated private enum CEA608SidecarEncoder {
    private struct ScheduledPair {
        var frame: Int64
        var first: UInt8
        var second: UInt8
    }

    static func encode(
        cues: [ProfessionalTimedCue],
        format: ClosedCaptionSidecarFormat,
        frameRate: ProfessionalFrameRate
    ) throws -> Data {
        let schedule = makeSchedule(cues: cues, frameRate: frameRate)
        guard !schedule.isEmpty else {
            throw ProfessionalSubtitleDeliveryError.noTimedSubtitles
        }
        switch format {
        case .scc:
            return encodeSCC(schedule: schedule, frameRate: frameRate)
        case .mcc:
            return encodeMCC(schedule: schedule, frameRate: frameRate)
        }
    }

    private static func makeSchedule(
        cues: [ProfessionalTimedCue],
        frameRate: ProfessionalFrameRate
    ) -> [ScheduledPair] {
        var result: [ScheduledPair] = []
        var nextAvailableFrame: Int64 = 0

        for cue in cues {
            let startFrame = max(
                nextAvailableFrame,
                frameRate.frameIndex(for: cue.startTime)
            )
            let requestedEnd = frameRate.frameIndex(for: cue.endTime)
            let endFrame = max(startFrame + 2, requestedEnd)
            var loadWords: [(UInt8, UInt8)] = [
                (0x94, 0xAE), (0x94, 0xAE), // Erase non-displayed memory
                (0x94, 0x20), (0x94, 0x20)  // Resume caption loading
            ]
            let lines = captionLines(cue.text)
            for (lineIndex, line) in lines.enumerated() {
                // Row 14 for the first line and row 15 for the second.
                let pac: (UInt8, UInt8) = lineIndex == 0
                    ? (0x94, 0x40)
                    : (0x94, 0xE0)
                loadWords.append(pac)
                loadWords.append(pac)
                loadWords.append(contentsOf: textWords(line))
            }

            let eocWords: [(UInt8, UInt8)] = [
                (0x94, 0x2F), (0x94, 0x2F)
            ]
            let earliestLoad = max(
                nextAvailableFrame,
                startFrame - Int64(loadWords.count + eocWords.count)
            )
            var frame = earliestLoad
            for word in loadWords {
                result.append(
                    ScheduledPair(frame: frame, first: word.0, second: word.1)
                )
                frame += 1
            }
            frame = max(frame, startFrame - 1)
            for word in eocWords {
                result.append(
                    ScheduledPair(frame: frame, first: word.0, second: word.1)
                )
                frame += 1
            }

            let clearFrame = max(frame, endFrame)
            result.append(
                ScheduledPair(frame: clearFrame, first: 0x94, second: 0x2C)
            )
            result.append(
                ScheduledPair(frame: clearFrame + 1, first: 0x94, second: 0x2C)
            )
            nextAvailableFrame = clearFrame + 2
        }
        return result.sorted {
            if $0.frame == $1.frame {
                if $0.first == $1.first { return $0.second < $1.second }
                return $0.first < $1.first
            }
            return $0.frame < $1.frame
        }
    }

    private static func captionLines(_ rawText: String) -> [String] {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
        var rows: [String] = []
        for paragraph in normalized.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            var remaining = String(paragraph)
                .trimmingCharacters(in: .whitespaces)
            if remaining.isEmpty, rows.count < 2 {
                rows.append(" ")
            }
            while !remaining.isEmpty, rows.count < 2 {
                let candidate = String(remaining.prefix(32))
                let splitOffset: Int
                if remaining.count > 32,
                   let whitespace = candidate.lastIndex(where: {
                       $0.isWhitespace
                   }) {
                    splitOffset = candidate.distance(
                        from: candidate.startIndex,
                        to: whitespace
                    )
                } else {
                    splitOffset = candidate.count
                }
                let boundary = remaining.index(
                    remaining.startIndex,
                    offsetBy: max(1, splitOffset)
                )
                rows.append(
                    String(remaining[..<boundary])
                        .trimmingCharacters(in: .whitespaces)
                )
                remaining = String(remaining[boundary...])
                    .trimmingCharacters(in: .whitespaces)
            }
            if rows.count == 2 { break }
        }
        if rows.isEmpty { rows = [" "] }
        return rows
    }

    private static func textWords(_ text: String) -> [(UInt8, UInt8)] {
        var bytes = text.unicodeScalars.map { scalar -> UInt8 in
            let value = scalar.value
            guard value >= 0x20, value <= 0x7E else {
                return oddParity(0x3F)
            }
            return oddParity(UInt8(value))
        }
        if bytes.count.isMultiple(of: 2) == false {
            bytes.append(oddParity(0x20))
        }
        return stride(from: 0, to: bytes.count, by: 2).map {
            (bytes[$0], bytes[$0 + 1])
        }
    }

    private static func oddParity(_ sevenBitValue: UInt8) -> UInt8 {
        let value = sevenBitValue & 0x7F
        return value.nonzeroBitCount.isMultiple(of: 2)
            ? value | 0x80
            : value
    }

    private static func encodeSCC(
        schedule: [ScheduledPair],
        frameRate: ProfessionalFrameRate
    ) -> Data {
        var runs: [[ScheduledPair]] = []
        for pair in schedule {
            if let previous = runs.last?.last,
               pair.frame == previous.frame + 1 {
                runs[runs.count - 1].append(pair)
            } else {
                runs.append([pair])
            }
        }

        let body = runs.compactMap { run -> String? in
            guard let first = run.first else { return nil }
            // SCC uses a colon in its timecode field even though its clock is
            // conventionally 29.97 drop-frame.
            let timecode = frameRate.timecode(forFrame: first.frame)
                .replacingOccurrences(of: ";", with: ":")
            let words = run.map {
                String(format: "%02X%02X", $0.first, $0.second)
            }
            .joined(separator: " ")
            return "\(timecode)\t\(words)"
        }
        .joined(separator: "\r\n\r\n")

        return Data(
            ("Scenarist_SCC V1.0\r\n\r\n\(body)\r\n").utf8
        )
    }

    private static func encodeMCC(
        schedule: [ScheduledPair],
        frameRate: ProfessionalFrameRate
    ) -> Data {
        let header = mccHeader(frameRate: frameRate)
        let lines = schedule.enumerated().map { index, pair in
            let timecode = frameRate.timecode(forFrame: pair.frame)
                .replacingOccurrences(of: ";", with: ":")
            let packet = mccANCPacket(
                pair: pair,
                sequence: UInt16(truncatingIfNeeded: index),
                frameRate: frameRate
            )
            return "\(timecode)\t\(mccEncodedBytes(packet))"
        }
        return Data(
            (header + lines.joined(separator: "\r\n") + "\r\n").utf8
        )
    }

    private static func mccHeader(
        frameRate: ProfessionalFrameRate
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        let creationDate = formatter.string(from: Date())
        formatter.dateFormat = "HH:mm:ss"
        let creationTime = formatter.string(from: Date())
        let dropSuffix = frameRate.isDropFrame ? "DF" : ""

        return """
        File Format=MacCaption_MCC V2.0

        ///////////////////////////////////////////////////////////////////////////////////
        // Computer Prompting and Captioning Company
        // Ancillary Data Packet Transfer File
        //
        // Permission to generate this format is granted provided that
        // 1. This ANC Transfer file format is used on an as-is basis and no warranty is given, and
        // 2. This entire descriptive information text is included in a generated .mcc file.
        //
        // General file format:
        // HH:MM:SS:FF(tab)[Hexadecimal ANC data in groups of 2 characters]
        // Hexadecimal data starts with the Ancillary Data Packet DID (Data ID defined in S291M)
        // and concludes with the Check Sum following the User Data Words.
        // Each time code line must contain at most one complete ancillary data packet.
        // To transfer additional ANC Data successive lines may contain identical time code.
        // Time Code Rate=[24, 25, 30, 30DF, 50, 60, 60DF]
        //
        // ANC data bytes may be represented by one ASCII character according to the following schema:
        // G FAh 00h 00h
        // H 2 x (FAh 00h 00h)
        // I 3 x (FAh 00h 00h)
        // J 4 x (FAh 00h 00h)
        // K 5 x (FAh 00h 00h)
        // L 6 x (FAh 00h 00h)
        // M 7 x (FAh 00h 00h)
        // N 8 x (FAh 00h 00h)
        // O 9 x (FAh 00h 00h)
        // P FBh 80h 80h
        // Q FCh 80h 80h
        // R FDh 80h 80h
        // S 96h 69h
        // T 61h 01h
        // U E1h 00h 00h 00h
        // Z 00h
        //
        ///////////////////////////////////////////////////////////////////////////////////

        UUID=\(UUID().uuidString.uppercased())
        Creation Program=Strophe
        Creation Date=\(creationDate)
        Creation Time=\(creationTime)
        Time Code Rate=\(frameRate.nominalFramesPerSecond)\(dropSuffix)

        """
    }

    /// Builds one CEA-708 Caption Distribution Packet carried by a SMPTE 291
    /// ANC packet. The CC data section contains one valid CEA-608 field-one
    /// pair (`cc_type = 0`).
    private static func mccANCPacket(
        pair: ScheduledPair,
        sequence: UInt16,
        frameRate: ProfessionalFrameRate
    ) -> [UInt8] {
        let sequenceHigh = UInt8((sequence >> 8) & 0xFF)
        let sequenceLow = UInt8(sequence & 0xFF)
        var cdp: [UInt8] = [
            0x96, 0x69, 0x00,
            cdpFrameRateByte(frameRate),
            0x43,
            sequenceHigh, sequenceLow,
            0x72,
            0xE1,
            0xFC, pair.first, pair.second,
            0x74,
            sequenceHigh, sequenceLow,
            0x00
        ]
        cdp[2] = UInt8(cdp.count)
        cdp[cdp.count - 1] = UInt8(
            truncatingIfNeeded: -cdp.dropLast().reduce(0) {
                $0 + Int($1)
            }
        )

        let did: UInt8 = 0x61
        let sdid: UInt8 = 0x01
        let dataCount = UInt8(cdp.count)
        let checksum = UInt8(
            truncatingIfNeeded:
                Int(did)
                + Int(sdid)
                + Int(dataCount)
                + cdp.reduce(0) { $0 + Int($1) }
        )
        return [did, sdid, dataCount] + cdp + [checksum]
    }

    private static func cdpFrameRateByte(
        _ frameRate: ProfessionalFrameRate
    ) -> UInt8 {
        switch (
            frameRate.numerator,
            frameRate.denominator
        ) {
        case (24, 1): return 0x2F
        case (25, 1): return 0x3F
        case (30_000, 1_001): return 0x4F
        case (30, 1): return 0x5F
        case (50, 1): return 0x6F
        case (60_000, 1_001): return 0x7F
        case (60, 1): return 0x8F
        default: return 0x5F
        }
    }

    /// Applies the aliases defined by the MCC transfer format. Hex remains
    /// valid for every byte, while aliases make repeated padding compact.
    private static func mccEncodedBytes(_ bytes: [UInt8]) -> String {
        var result = ""
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0xFA {
                var repetitions = 0
                while repetitions < 9,
                      index + 2 < bytes.count,
                      bytes[index] == 0xFA,
                      bytes[index + 1] == 0,
                      bytes[index + 2] == 0 {
                    repetitions += 1
                    index += 3
                }
                if repetitions > 0 {
                    let scalar = UnicodeScalar(
                        Int(Character("G").asciiValue!) + repetitions - 1
                    )!
                    result.unicodeScalars.append(scalar)
                    continue
                }
            }

            if index + 2 < bytes.count,
               (0xFB...0xFD).contains(bytes[index]),
               bytes[index + 1] == 0x80,
               bytes[index + 2] == 0x80 {
                let scalar = UnicodeScalar(
                    Int(Character("P").asciiValue!)
                        + Int(bytes[index] - 0xFB)
                )!
                result.unicodeScalars.append(scalar)
                index += 3
                continue
            }

            if index + 1 < bytes.count,
               bytes[index] == 0x96,
               bytes[index + 1] == 0x69 {
                result.append("S")
                index += 2
                continue
            }

            if index + 1 < bytes.count,
               bytes[index] == 0x61,
               bytes[index + 1] == 0x01 {
                result.append("T")
                index += 2
                continue
            }

            if bytes[index] == 0 {
                result.append("Z")
                index += 1
                continue
            }

            result += String(format: "%02X", bytes[index])
            index += 1
        }
        return result
    }
}

// MARK: - EBU Tech 3264 STL

nonisolated private enum EBUSTLEncoder {
    private static let gsiSize = 1_024
    private static let ttiSize = 128

    static func encode(
        cues: [ProfessionalTimedCue],
        frameRate: Int,
        programmeTitle: String
    ) -> Data {
        let normalizedRate = frameRate == 25 ? 25 : 30
        let encoded = cues.enumerated().map { index, cue in
            makeTTIBlocks(
                cue: cue,
                subtitleNumber: UInt16(clamping: index + 1),
                frameRate: normalizedRate
            )
        }
        let totalBlocks = encoded.reduce(0) { $0 + $1.count }
        let language = languageCode(cues.compactMap(\.languageCode).first)
        var result = makeGSI(
            frameRate: normalizedRate,
            programmeTitle: programmeTitle,
            languageCode: language,
            totalBlocks: totalBlocks,
            totalSubtitles: cues.count,
            firstCueTime: cues.first?.startTime ?? 0
        )
        for blocks in encoded {
            for block in blocks {
                result.append(block)
            }
        }
        return result
    }

    private static func makeGSI(
        frameRate: Int,
        programmeTitle: String,
        languageCode: String,
        totalBlocks: Int,
        totalSubtitles: Int,
        firstCueTime: Double
    ) -> Data {
        var data = Data(repeating: 0x20, count: gsiSize)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMdd"
        let date = formatter.string(from: Date())

        setASCII("850", in: &data, range: 0..<3)
        setASCII(frameRate == 25 ? "STL25.01" : "STL30.01", in: &data, range: 3..<11)
        setASCII("0", in: &data, range: 11..<12)
        setASCII("00", in: &data, range: 12..<14)
        setASCII(languageCode, in: &data, range: 14..<16)
        setASCII(programmeTitle.isEmpty ? "Strophe Subtitles" : programmeTitle, in: &data, range: 16..<48)
        setASCII(date, in: &data, range: 224..<230)
        setASCII(date, in: &data, range: 230..<236)
        setASCII("00", in: &data, range: 236..<238)
        setASCII(decimal(totalBlocks, width: 5), in: &data, range: 238..<243)
        setASCII(decimal(totalSubtitles, width: 5), in: &data, range: 243..<248)
        setASCII("001", in: &data, range: 248..<251)
        setASCII("40", in: &data, range: 251..<253)
        setASCII("23", in: &data, range: 253..<255)
        setASCII("1", in: &data, range: 255..<256)
        setASCII("00000000", in: &data, range: 256..<264)
        setASCII(
            compactTimecode(firstCueTime, frameRate: frameRate),
            in: &data,
            range: 264..<272
        )
        setASCII("1", in: &data, range: 272..<273)
        setASCII("1", in: &data, range: 273..<274)
        setASCII("GBR", in: &data, range: 274..<277)
        setASCII("Strophe", in: &data, range: 277..<309)
        setASCII("Strophe", in: &data, range: 309..<341)
        data.replaceSubrange(448..<1_024, with: repeatElement(UInt8(0), count: 576))
        return data
    }

    private static func makeTTIBlocks(
        cue: ProfessionalTimedCue,
        subtitleNumber: UInt16,
        frameRate: Int
    ) -> [Data] {
        let text = textBytes(cue.text)
        let chunks = stride(from: 0, to: max(1, text.count), by: 111).map {
            start -> ArraySlice<UInt8> in
            guard !text.isEmpty else { return [] }
            return text[start..<min(start + 111, text.count)]
        }
        let start = binaryTimecode(cue.startTime, frameRate: frameRate)
        let end = binaryTimecode(cue.endTime, frameRate: frameRate)

        return chunks.enumerated().map { index, chunk in
            var block = Data(repeating: 0x8F, count: ttiSize)
            block[0] = 0
            block[1] = UInt8(subtitleNumber & 0x00FF)
            block[2] = UInt8((subtitleNumber & 0xFF00) >> 8)
            block[3] = index == chunks.count - 1
                ? 0xFF
                : UInt8(clamping: index)
            block[4] = 0
            block.replaceSubrange(5..<9, with: start)
            block.replaceSubrange(9..<13, with: end)
            block[13] = 20
            block[14] = 2
            block[15] = 0
            if !chunk.isEmpty {
                block.replaceSubrange(
                    16..<(16 + chunk.count),
                    with: chunk
                )
            }
            let terminatorIndex = min(127, 16 + chunk.count)
            block[terminatorIndex] = 0x8F
            return block
        }
    }

    private static func textBytes(_ text: String) -> [UInt8] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.unicodeScalars.flatMap { scalar -> [UInt8] in
            if scalar.value == 0x0A { return [0x8A] }
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                return [UInt8(scalar.value)]
            }
            if scalar.value == 0x00A0 { return [0xA0] }

            let decomposed = Array(
                String(scalar)
                    .decomposedStringWithCanonicalMapping
                    .unicodeScalars
            )
            if decomposed.count == 2,
               let accent = iso6937AccentByte(decomposed[1]),
               decomposed[0].value >= 0x20,
               decomposed[0].value <= 0x7E {
                // ISO 6937 uses the "floating accent" convention: the
                // non-spacing diacritic is written before the base letter.
                return [accent, UInt8(decomposed[0].value)]
            }

            return [iso6937DirectByte(scalar) ?? 0x3F]
        }
    }

    private static func iso6937AccentByte(
        _ scalar: UnicodeScalar
    ) -> UInt8? {
        switch scalar.value {
        case 0x0300: return 0xC1 // grave
        case 0x0301: return 0xC2 // acute
        case 0x0302: return 0xC3 // circumflex
        case 0x0303: return 0xC4 // tilde
        case 0x0304: return 0xC5 // macron
        case 0x0306: return 0xC6 // breve
        case 0x0307: return 0xC7 // dot above
        case 0x0308: return 0xC8 // diaeresis
        case 0x030A: return 0xCA // ring above
        case 0x0327: return 0xCB // cedilla
        case 0x030B: return 0xCD // double acute
        case 0x0328: return 0xCE // ogonek
        case 0x030C: return 0xCF // caron
        default: return nil
        }
    }

    private static func iso6937DirectByte(
        _ scalar: UnicodeScalar
    ) -> UInt8? {
        switch scalar.value {
        case 0x00A1: return 0xA1 // inverted exclamation
        case 0x00A2: return 0xA2 // cent
        case 0x00A3: return 0xA3 // pound
        case 0x00A5: return 0xA5 // yen
        case 0x00A7: return 0xA7 // section
        case 0x2018: return 0xA9
        case 0x201C: return 0xAA
        case 0x00AB: return 0xAB // left guillemet
        case 0x2190: return 0xAC
        case 0x2191: return 0xAD
        case 0x2192: return 0xAE
        case 0x2193: return 0xAF
        case 0x00B0: return 0xB0 // degree
        case 0x00B1: return 0xB1 // plus-minus
        case 0x00B2: return 0xB2
        case 0x00B3: return 0xB3
        case 0x00D7: return 0xB4 // multiplication
        case 0x00B5: return 0xB5 // micro
        case 0x00B6: return 0xB6 // pilcrow
        case 0x00B7: return 0xB7 // middle dot
        case 0x00F7: return 0xB8 // division
        case 0x2019: return 0xB9
        case 0x201D: return 0xBA
        case 0x00BB: return 0xBB // right guillemet
        case 0x00BC: return 0xBC
        case 0x00BD: return 0xBD
        case 0x00BE: return 0xBE
        case 0x00BF: return 0xBF // inverted question
        case 0x2014: return 0xD0
        case 0x00C6: return 0xE1 // AE ligature
        case 0x0110: return 0xE2 // D with stroke
        case 0x00D0: return 0xE3 // Eth
        case 0x0126: return 0xE4 // H with stroke
        case 0x0141: return 0xE8 // L with stroke
        case 0x00D8: return 0xE9 // O with stroke
        case 0x0152: return 0xEA // OE ligature
        case 0x00DE: return 0xEC // Thorn
        case 0x00DF: return 0xFB // sharp s
        case 0x00E6: return 0xF1 // ae ligature
        case 0x0111: return 0xF2 // d with stroke
        case 0x00F0: return 0xF3 // eth
        case 0x0127: return 0xF4 // h with stroke
        case 0x0131: return 0xF5 // dotless i
        case 0x0142: return 0xF8 // l with stroke
        case 0x00F8: return 0xF9 // o with stroke
        case 0x0153: return 0xFA // oe ligature
        case 0x00FE: return 0xFC // thorn
        default: return nil
        }
    }

    private static func binaryTimecode(
        _ seconds: Double,
        frameRate: Int
    ) -> [UInt8] {
        let totalFrames = max(0, Int((seconds * Double(frameRate)).rounded()))
        let frames = totalFrames % frameRate
        let totalSeconds = totalFrames / frameRate
        return [
            UInt8(clamping: (totalSeconds / 3_600) % 24),
            UInt8(clamping: (totalSeconds / 60) % 60),
            UInt8(clamping: totalSeconds % 60),
            UInt8(clamping: frames)
        ]
    }

    private static func compactTimecode(
        _ seconds: Double,
        frameRate: Int
    ) -> String {
        binaryTimecode(seconds, frameRate: frameRate)
            .map { String(format: "%02d", $0) }
            .joined()
    }

    private static func languageCode(_ rawValue: String?) -> String {
        guard let primary = rawValue?
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first else {
            return "00"
        }
        switch primary {
        case "en": return "09"
        case "es": return "0A"
        case "fr": return "0F"
        case "de": return "08"
        case "it": return "15"
        case "pt": return "21"
        case "ja": return "69"
        case "zh": return "7A"
        case "ko": return "65"
        default: return "00"
        }
    }

    private static func decimal(_ value: Int, width: Int) -> String {
        String(format: "%0*d", width, max(0, min(value, 99_999)))
    }

    private static func setASCII(
        _ value: String,
        in data: inout Data,
        range: Range<Int>
    ) {
        let bytes = value.unicodeScalars.map {
            $0.value >= 0x20 && $0.value <= 0x7E
                ? UInt8($0.value)
                : UInt8(ascii: "?")
        }
        let count = min(bytes.count, range.count)
        guard count > 0 else { return }
        data.replaceSubrange(
            range.lowerBound..<(range.lowerBound + count),
            with: bytes.prefix(count)
        )
    }
}
