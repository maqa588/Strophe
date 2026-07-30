//
//  ASSProcessor.swift
//  SwiftSub
//
//  Lossless ASS/SSA import and export.
//

import Foundation

struct ASSProcessor: SubtitleProcessor {
    let format: SubtitleFormat = .ass

    private static let defaultEventFormat = [
        "Layer", "Start", "End", "Style", "Name",
        "MarginL", "MarginR", "MarginV", "Effect", "Text"
    ]

    func parseDocument(text: String, sourceFileName: String?) -> SubtitleParseResult {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let lines = normalizedText.components(separatedBy: "\n")
        let eventsIndex = lines.firstIndex {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("[Events]") == .orderedSame
        }
        let preambleLines = eventsIndex.map { Array(lines[..<$0]) } ?? lines
        let preamble = preambleLines.joined(separator: "\n")
        let documentID = UUID()
        let styleMetadata = parseStyleMetadata(from: preambleLines)

        var eventFormat = Self.defaultEventFormat
        var preservedEventLines: [String] = []
        var blocks: [SubtitleBlock] = []
        var diagnostics: [SubtitleParseDiagnostic] = []

        guard let eventsIndex else {
            diagnostics.append(
                SubtitleParseDiagnostic(
                    severity: .error,
                    message: "ASS document has no [Events] section."
                )
            )
            let source = SubtitleSourceDocument(
                id: documentID,
                format: .ass,
                sourceFileName: sourceFileName,
                ass: ASSDocumentMetadata(
                    preamble: preamble,
                    eventFormat: eventFormat,
                    styleFormat: styleMetadata.format,
                    styles: styleMetadata.styles,
                    playResolutionX: styleMetadata.playResolutionX,
                    playResolutionY: styleMetadata.playResolutionY
                )
            )
            return SubtitleParseResult(
                document: SubtitleDocument(format: .ass, blocks: [], source: source),
                diagnostics: diagnostics
            )
        }

        for (offset, line) in lines[(eventsIndex + 1)...].enumerated() {
            let lineNumber = eventsIndex + offset + 2
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let formatValue = value(afterPrefix: "Format:", in: trimmed) {
                let parsedFormat = formatValue.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !parsedFormat.isEmpty {
                    eventFormat = parsedFormat
                }
                continue
            }

            guard let colon = trimmed.firstIndex(of: ":") else {
                preservedEventLines.append(line)
                continue
            }
            let eventType = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            guard eventType.caseInsensitiveCompare("Dialogue") == .orderedSame else {
                preservedEventLines.append(line)
                continue
            }

            let recordStart = trimmed.index(after: colon)
            let record = trimmed[recordStart...].trimmingCharacters(in: .whitespaces)
            guard let values = splitRecord(record, fieldCount: eventFormat.count) else {
                diagnostics.append(
                    SubtitleParseDiagnostic(
                        severity: .warning,
                        line: lineNumber,
                        message: "Skipped an ASS dialogue with fewer fields than its Format declaration."
                    )
                )
                continue
            }

            var fields: [String: String] = [:]
            for (fieldName, value) in zip(eventFormat, values) {
                fields[fieldName.lowercased()] = value
            }
            guard let startValue = fields["start"],
                  let endValue = fields["end"],
                  let rawPayload = fields["text"] else {
                diagnostics.append(
                    SubtitleParseDiagnostic(
                        severity: .warning,
                        line: lineNumber,
                        message: "Skipped an ASS dialogue because Start, End or Text is missing."
                    )
                )
                continue
            }

            let styledText = PreservedStyledText.ass(rawPayload)
            let cue = ASSCueMetadata(
                eventType: String(eventType),
                fields: fields,
                styledText: styledText
            )
            blocks.append(
                SubtitleBlock(
                    startTime: SubtitleTimeFormatter.parseTimestamp(startValue),
                    endTime: SubtitleTimeFormatter.parseTimestamp(endValue),
                    text: styledText.plainTextAtImport,
                    interchangeMetadata: SubtitleCueInterchangeMetadata(
                        sourceDocumentID: documentID,
                        ass: cue
                    )
                )
            )
        }

        let source = SubtitleSourceDocument(
            id: documentID,
            format: .ass,
            sourceFileName: sourceFileName,
            ass: ASSDocumentMetadata(
                preamble: preamble,
                eventFormat: eventFormat,
                preservedEventLines: preservedEventLines,
                styleFormat: styleMetadata.format,
                styles: styleMetadata.styles,
                playResolutionX: styleMetadata.playResolutionX,
                playResolutionY: styleMetadata.playResolutionY
            )
        )
        return SubtitleParseResult(
            document: SubtitleDocument(format: .ass, blocks: blocks, source: source),
            diagnostics: diagnostics
        )
    }

    func generate(document: SubtitleDocument) -> String {
        let metadata = document.source?.ass
        var output = metadata?.preamble ?? Self.defaultPreamble
        while output.hasSuffix("\n\n") {
            output.removeLast()
        }
        if !output.isEmpty, !output.hasSuffix("\n") {
            output += "\n"
        }
        output += "[Events]\n"

        let eventFormat = metadata?.eventFormat.isEmpty == false
            ? metadata!.eventFormat
            : Self.defaultEventFormat
        output += "Format: \(eventFormat.joined(separator: ", "))\n"

        if let preservedLines = metadata?.preservedEventLines {
            for line in preservedLines {
                output += line
                if !line.hasSuffix("\n") { output += "\n" }
            }
        }

        for block in document.blocks {
            let cue = block.interchangeMetadata?.ass
            var values = cue?.fields ?? [:]
            values["start"] = SubtitleTimeFormatter.format(seconds: block.startTime, format: .ass)
            values["end"] = SubtitleTimeFormatter.format(seconds: block.endTime, format: .ass)
            values["text"] = encodedText(
                for: block,
                styledText: cue?.styledText,
                karaokeState: document.karaokeExportStates[block.id]
            )

            let serializedFields = eventFormat.map { fieldName -> String in
                let key = fieldName.lowercased()
                if let value = values[key] { return value }
                return defaultValue(forEventField: key)
            }
            output += "\(cue?.eventType ?? "Dialogue"): \(serializedFields.joined(separator: ","))\n"
        }
        return output
    }

    private func encodedText(
        for block: SubtitleBlock,
        styledText: PreservedStyledText?,
        karaokeState: SubtitleKaraokeExportState?
    ) -> String {
        // A parser-to-writer round trip has no project presentation state and
        // must remain lossless, including any source Karaoke tags.
        guard let karaokeState else {
            return styledText?.encoded(editableText: block.text)
                ?? encodePlainText(block.text)
        }

        let preservedTokens = (styledText?.tokens ?? []).compactMap {
            sanitizedASSOverrideToken($0)
        }
        switch karaokeState {
        case .disabled:
            return encode(
                text: block.text,
                preservedTokens: preservedTokens
            )
        case .enabled(let program):
            let cueDuration = max(0, block.endTime - block.startTime)
            guard let exportProgram = program.reconciled(
                to: block.text,
                cueDuration: cueDuration
            ) else {
                return encode(
                    text: block.text,
                    preservedTokens: preservedTokens
                )
            }
            return encode(
                text: block.text,
                preservedTokens: preservedTokens,
                karaokeProgram: exportProgram
            )
        }
    }

    private func encode(
        text: String,
        preservedTokens: [PreservedInlineToken],
        karaokeProgram: KaraokeProgram? = nil
    ) -> String {
        let characters = Array(text)
        let groupedTokens = Dictionary(grouping: preservedTokens) {
            min(max(0, $0.characterOffset), characters.count)
        }
        let karaokeTags = karaokeProgram.map {
            karaokeTagsByCharacterOffset(program: $0)
        } ?? [:]
        let templateTag = karaokeProgram.map {
            assTemplateOverride($0.template)
        }

        var result = ""
        for offset in 0...characters.count {
            if let tokens = groupedTokens[offset] {
                for token in tokens {
                    result += token.rawValue
                }
            }
            if offset == 0, let templateTag {
                result += templateTag
            }
            if let tags = karaokeTags[offset] {
                result += tags.joined()
            }
            guard offset < characters.count else { continue }
            result += encodePlainCharacter(characters[offset])
        }
        return result
    }

    private func karaokeTagsByCharacterOffset(
        program: KaraokeProgram
    ) -> [Int: [String]] {
        let tagName = program.template.revealMode == .sweep ? "kf" : "k"
        let ordered = program.units.sorted {
            $0.characterStart == $1.characterStart
                ? $0.startOffset < $1.startOffset
                : $0.characterStart < $1.characterStart
        }
        var cursorCentiseconds = 0
        var tags: [Int: [String]] = [:]

        for unit in ordered {
            let start = max(
                cursorCentiseconds,
                Int((max(0, unit.startOffset) * 100).rounded())
            )
            let rawEnd = Int((max(0, unit.endOffset) * 100).rounded())
            let end = max(start + 1, rawEnd)
            let gap = start - cursorCentiseconds
            if gap > 0 {
                // Consecutive Karaoke tags advance libass/Aegisub's Karaoke
                // clock without introducing a visible spacer glyph.
                tags[unit.characterStart, default: []].append("{\\k\(gap)}")
            }
            tags[unit.characterStart, default: []].append(
                "{\\\(tagName)\(end - start)}"
            )
            cursorCentiseconds = end
        }
        return tags
    }

    private func sanitizedASSOverrideToken(
        _ token: PreservedInlineToken
    ) -> PreservedInlineToken? {
        let raw = token.rawValue
        guard raw.hasPrefix("{"), raw.hasSuffix("}") else {
            return token
        }
        let content = String(raw.dropFirst().dropLast())
        guard let regex = try? NSRegularExpression(
            pattern: #"\\k(?:f|o)?\d+"#,
            options: [.caseInsensitive]
        ) else {
            return token
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        let stripped = regex.stringByReplacingMatches(
            in: content,
            range: range,
            withTemplate: ""
        )
        guard !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return PreservedInlineToken(
            characterOffset: token.characterOffset,
            rawValue: "{\(stripped)}"
        )
    }

    private func assTemplateOverride(
        _ template: KaraokeTemplateConfiguration
    ) -> String {
        let active = assColorComponents(template.activeColorHex)
        let inactive = assColorComponents(template.inactiveColorHex)
        return """
        {\\1c&H\(active.bgr)&\\2c&H\(inactive.bgr)&\
        \\1a&H\(active.alpha)&\\2a&H\(inactive.alpha)&}
        """
    }

    private func assColorComponents(
        _ hex: String
    ) -> (bgr: String, alpha: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard (raw.count == 6 || raw.count == 8),
              let value = UInt64(raw, radix: 16) else {
            return ("FFFFFF", "00")
        }
        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let opacity: UInt64
        if raw.count == 8 {
            red = (value >> 24) & 0xff
            green = (value >> 16) & 0xff
            blue = (value >> 8) & 0xff
            opacity = value & 0xff
        } else {
            red = (value >> 16) & 0xff
            green = (value >> 8) & 0xff
            blue = value & 0xff
            opacity = 0xff
        }
        return (
            String(format: "%02X%02X%02X", blue, green, red),
            String(format: "%02X", 0xff - opacity)
        )
    }

    private func encodePlainText(_ text: String) -> String {
        text.map(encodePlainCharacter).joined()
    }

    private func encodePlainCharacter(_ character: Character) -> String {
        if character == "\n" {
            return "\\N"
        }
        if character == "\u{00A0}" {
            return "\\h"
        }
        return String(character)
    }

    private func parseStyleMetadata(
        from lines: [String]
    ) -> (
        format: [String],
        styles: [ASSStyleRecord],
        playResolutionX: Double?,
        playResolutionY: Double?
    ) {
        var currentSection = ""
        var styleFormat: [String] = []
        var styles: [ASSStyleRecord] = []
        var playResolutionX: Double?
        var playResolutionY: Double?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                currentSection = trimmed.lowercased()
                continue
            }

            if let value = value(afterPrefix: "PlayResX:", in: trimmed) {
                playResolutionX = Double(value.trimmingCharacters(in: .whitespaces))
            } else if let value = value(afterPrefix: "PlayResY:", in: trimmed) {
                playResolutionY = Double(value.trimmingCharacters(in: .whitespaces))
            }

            guard currentSection == "[v4+ styles]" || currentSection == "[v4 styles]" else {
                continue
            }
            if let value = value(afterPrefix: "Format:", in: trimmed) {
                styleFormat = value.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard let value = value(afterPrefix: "Style:", in: trimmed),
                  !styleFormat.isEmpty,
                  let fieldValues = splitRecord(value, fieldCount: styleFormat.count) else {
                continue
            }
            var values: [String: String] = [:]
            for (fieldName, fieldValue) in zip(styleFormat, fieldValues) {
                values[fieldName.lowercased()] = fieldValue
            }
            styles.append(ASSStyleRecord(values: values, rawLine: line))
        }

        return (styleFormat, styles, playResolutionX, playResolutionY)
    }

    private func splitRecord(_ record: String, fieldCount: Int) -> [String]? {
        guard fieldCount > 0 else { return [] }
        var fields: [String] = []
        var remainder = record[record.startIndex...]

        for _ in 0..<(fieldCount - 1) {
            guard let comma = remainder.firstIndex(of: ",") else { return nil }
            fields.append(String(remainder[..<comma]).trimmingCharacters(in: .whitespaces))
            remainder = remainder[remainder.index(after: comma)...]
        }
        fields.append(String(remainder))
        return fields
    }

    private func value(afterPrefix prefix: String, in value: String) -> String? {
        guard value.count >= prefix.count else { return nil }
        let end = value.index(value.startIndex, offsetBy: prefix.count)
        guard value[..<end].caseInsensitiveCompare(prefix) == .orderedSame else { return nil }
        return String(value[end...])
    }

    private func defaultValue(forEventField field: String) -> String {
        switch field {
        case "layer", "marked", "marginl", "marginr", "marginv":
            return "0"
        case "style":
            return "Default"
        case "start", "end":
            return "0:00:00.00"
        default:
            return ""
        }
    }

    private static let defaultPreamble = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1920
    PlayResY: 1080

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1

    """
}
