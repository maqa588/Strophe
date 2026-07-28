//
//  SubtitleInterchange.swift
//  Strophe
//
//  Lossless interchange metadata shared by subtitle import, editing and export.
//

import Foundation

/// A parsed subtitle document. The editor works with `blocks`, while `source`
/// keeps format-specific information that must survive a round trip.
public struct SubtitleDocument: Equatable, Sendable {
    public var format: SubtitleFormat
    public var blocks: [SubtitleBlock]
    public var source: SubtitleSourceDocument?

    public init(
        format: SubtitleFormat,
        blocks: [SubtitleBlock],
        source: SubtitleSourceDocument? = nil
    ) {
        self.format = format
        self.blocks = blocks
        self.source = source
    }
}

public struct SubtitleParseDiagnostic: Equatable, Sendable {
    public enum Severity: String, Codable, Sendable {
        case warning
        case error
    }

    public var severity: Severity
    public var line: Int?
    public var message: String

    public init(severity: Severity, line: Int? = nil, message: String) {
        self.severity = severity
        self.line = line
        self.message = message
    }
}

public struct SubtitleParseResult: Equatable, Sendable {
    public var document: SubtitleDocument
    public var diagnostics: [SubtitleParseDiagnostic]

    public init(document: SubtitleDocument, diagnostics: [SubtitleParseDiagnostic] = []) {
        self.document = document
        self.diagnostics = diagnostics
    }
}

/// Project-level metadata from an imported subtitle file.
///
/// The optional format payloads deliberately use additive Codable fields
/// instead of an enum with associated values. Future Strophe releases can add
/// another format without making older project files undecodable.
public struct SubtitleSourceDocument: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var format: SubtitleFormat
    public var sourceFileName: String?
    public var ass: ASSDocumentMetadata?
    public var webVTT: WebVTTDocumentMetadata?
    public var lrc: LRCDocumentMetadata?

    public init(
        id: UUID = UUID(),
        format: SubtitleFormat,
        sourceFileName: String? = nil,
        ass: ASSDocumentMetadata? = nil,
        webVTT: WebVTTDocumentMetadata? = nil,
        lrc: LRCDocumentMetadata? = nil
    ) {
        self.id = id
        self.format = format
        self.sourceFileName = sourceFileName
        self.ass = ass
        self.webVTT = webVTT
        self.lrc = lrc
    }
}

public struct ASSDocumentMetadata: Codable, Equatable, Sendable {
    /// Everything before `[Events]`, preserved byte-for-byte after decoding.
    public var preamble: String
    public var eventFormat: [String]
    /// Event-section lines that Strophe does not edit (comments and extensions).
    public var preservedEventLines: [String]
    public var styleFormat: [String]
    public var styles: [ASSStyleRecord]
    public var playResolutionX: Double?
    public var playResolutionY: Double?

    public init(
        preamble: String,
        eventFormat: [String],
        preservedEventLines: [String] = [],
        styleFormat: [String] = [],
        styles: [ASSStyleRecord] = [],
        playResolutionX: Double? = nil,
        playResolutionY: Double? = nil
    ) {
        self.preamble = preamble
        self.eventFormat = eventFormat
        self.preservedEventLines = preservedEventLines
        self.styleFormat = styleFormat
        self.styles = styles
        self.playResolutionX = playResolutionX
        self.playResolutionY = playResolutionY
    }
}

public struct ASSStyleRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var values: [String: String]
    public var rawLine: String

    public init(id: UUID = UUID(), values: [String: String], rawLine: String) {
        self.id = id
        self.values = values
        self.rawLine = rawLine
    }

    public func value(named name: String) -> String? {
        values[name.lowercased()]
    }

    public var name: String {
        value(named: "name") ?? "Default"
    }
}

public struct WebVTTDocumentMetadata: Codable, Equatable, Sendable {
    /// Header, NOTE, STYLE and REGION blocks which are not editable cues.
    public var preservedBlocks: [String]

    public init(preservedBlocks: [String] = []) {
        self.preservedBlocks = preservedBlocks
    }
}

public struct LRCDocumentMetadata: Codable, Equatable, Sendable {
    /// Artist/album/offset and unknown metadata lines.
    public var metadataLines: [String]

    public init(metadataLines: [String] = []) {
        self.metadataLines = metadataLines
    }
}

/// Cue-level metadata. Every optional payload is retained in `.strophe`
/// projects and only interpreted by its matching exporter.
public struct SubtitleCueInterchangeMetadata: Codable, Equatable, Sendable {
    public var sourceDocumentID: UUID?
    public var ass: ASSCueMetadata?
    public var webVTT: WebVTTCueMetadata?
    public var srt: SRTCueMetadata?
    public var lrc: LRCCueMetadata?

    public init(
        sourceDocumentID: UUID? = nil,
        ass: ASSCueMetadata? = nil,
        webVTT: WebVTTCueMetadata? = nil,
        srt: SRTCueMetadata? = nil,
        lrc: LRCCueMetadata? = nil
    ) {
        self.sourceDocumentID = sourceDocumentID
        self.ass = ass
        self.webVTT = webVTT
        self.srt = srt
        self.lrc = lrc
    }
}

public struct ASSCueMetadata: Codable, Equatable, Sendable {
    public var eventType: String
    /// Lower-cased event field name to original field value.
    public var fields: [String: String]
    public var styledText: PreservedStyledText

    public init(eventType: String, fields: [String: String], styledText: PreservedStyledText) {
        self.eventType = eventType
        self.fields = fields
        self.styledText = styledText
    }

    public var styleName: String {
        fields["style"] ?? "Default"
    }
}

public struct WebVTTCueMetadata: Codable, Equatable, Sendable {
    public var identifier: String?
    public var settings: String
    public var styledText: PreservedStyledText

    public init(identifier: String? = nil, settings: String = "", styledText: PreservedStyledText) {
        self.identifier = identifier
        self.settings = settings
        self.styledText = styledText
    }
}

public struct SRTCueMetadata: Codable, Equatable, Sendable {
    public var identifier: String?
    public var timingSuffix: String

    public init(identifier: String? = nil, timingSuffix: String = "") {
        self.identifier = identifier
        self.timingSuffix = timingSuffix
    }
}

public struct LRCCueMetadata: Codable, Equatable, Sendable {
    public var originalTimestamp: String

    public init(originalTimestamp: String) {
        self.originalTimestamp = originalTimestamp
    }
}

public struct PreservedInlineToken: Codable, Equatable, Sendable {
    /// Character offset in the plain, editable text.
    public var characterOffset: Int
    public var rawValue: String

    public init(characterOffset: Int, rawValue: String) {
        self.characterOffset = characterOffset
        self.rawValue = rawValue
    }
}

/// Stores the exact imported payload as well as anchors for unknown markup.
/// If the visible text was not edited, export returns `rawText` exactly. If it
/// was edited, tokens are reinserted at their nearest valid character offsets.
public struct PreservedStyledText: Codable, Equatable, Sendable {
    public enum Dialect: String, Codable, Sendable {
        case ass
        case webVTT
    }

    public var rawText: String
    public var plainTextAtImport: String
    public var tokens: [PreservedInlineToken]
    public var dialect: Dialect

    public init(
        rawText: String,
        plainTextAtImport: String,
        tokens: [PreservedInlineToken],
        dialect: Dialect
    ) {
        self.rawText = rawText
        self.plainTextAtImport = plainTextAtImport
        self.tokens = tokens
        self.dialect = dialect
    }

    public static func ass(_ rawText: String) -> PreservedStyledText {
        tokenize(rawText, dialect: .ass)
    }

    public static func webVTT(_ rawText: String) -> PreservedStyledText {
        tokenize(rawText, dialect: .webVTT)
    }

    public func encoded(editableText: String) -> String {
        if editableText == plainTextAtImport {
            return rawText
        }

        let characters = Array(editableText)
        let groupedTokens = Dictionary(grouping: tokens) {
            min(max(0, $0.characterOffset), characters.count)
        }

        var result = ""
        for offset in 0...characters.count {
            if let anchored = groupedTokens[offset] {
                for token in anchored {
                    result += token.rawValue
                }
            }
            guard offset < characters.count else { continue }
            let character = characters[offset]
            switch dialect {
            case .ass:
                if character == "\n" {
                    result += "\\N"
                } else if character == "\u{00A0}" {
                    result += "\\h"
                } else {
                    result.append(character)
                }
            case .webVTT:
                result.append(character)
            }
        }
        return result
    }

    private static func tokenize(_ rawText: String, dialect: Dialect) -> PreservedStyledText {
        let characters = Array(rawText)
        var plain = ""
        var tokens: [PreservedInlineToken] = []
        var index = 0
        var plainOffset = 0

        while index < characters.count {
            let character = characters[index]
            switch dialect {
            case .ass:
                if character == "{",
                   let closingIndex = characters[(index + 1)...].firstIndex(of: "}") {
                    let rawToken = String(characters[index...closingIndex])
                    tokens.append(PreservedInlineToken(characterOffset: plainOffset, rawValue: rawToken))
                    index = closingIndex + 1
                    continue
                }
                if character == "\\", index + 1 < characters.count {
                    let escaped = characters[index + 1]
                    if escaped == "N" || escaped == "n" {
                        plain.append("\n")
                        plainOffset += 1
                        index += 2
                        continue
                    }
                    if escaped == "h" {
                        plain.append("\u{00A0}")
                        plainOffset += 1
                        index += 2
                        continue
                    }
                }
            case .webVTT:
                if character == "<",
                   let closingIndex = characters[(index + 1)...].firstIndex(of: ">") {
                    let rawToken = String(characters[index...closingIndex])
                    tokens.append(PreservedInlineToken(characterOffset: plainOffset, rawValue: rawToken))
                    index = closingIndex + 1
                    continue
                }
            }

            plain.append(character)
            plainOffset += 1
            index += 1
        }

        return PreservedStyledText(
            rawText: rawText,
            plainTextAtImport: plain,
            tokens: tokens,
            dialect: dialect
        )
    }
}
