import Foundation

struct AppleDictionaryDefinition: Sendable, Equatable {
    struct Sense: Sendable, Equatable {
        var number: String?
        var definition: String
        var examples: [String]
    }

    var headword: String
    var metadata: String
    var senses: [Sense]
}

enum AppleDictionaryDefinitionParser {
    private static let senseMarkerSequence = Array("①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳")
    private static let senseMarkers = Set<Character>(senseMarkerSequence)
    private static let exampleMarkers: Set<Character> = ["▸", "►", "▶"]

    static func parse(term: String, rawText: String) -> AppleDictionaryDefinition {
        let normalized = rawText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let firstSenseIndex = normalized.firstIndex { senseMarkers.contains($0) }
        let firstExampleIndex = normalized.firstIndex { exampleMarkers.contains($0) }
        let headerEnd = [firstSenseIndex, firstExampleIndex].compactMap { $0 }.min() ?? normalized.endIndex
        let header = String(normalized[..<headerEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let (headword, metadata) = parseHeader(term: term, header: header)

        let senses: [AppleDictionaryDefinition.Sense]
        if let firstSenseIndex {
            senses = parseNumberedSenses(String(normalized[firstSenseIndex...]))
        } else {
            let examples = splitExamples(String(normalized[headerEnd...])).examples
            senses = examples.isEmpty ? [] : [.init(number: nil, definition: "", examples: examples)]
        }

        return AppleDictionaryDefinition(
            headword: headword,
            metadata: metadata,
            senses: senses
        )
    }

    private static func parseHeader(term: String, header: String) -> (String, String) {
        guard !header.isEmpty else { return (term, "") }
        let parts = header.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        let candidate = parts.first.map(String.init) ?? term
        let headword = candidate.localizedCaseInsensitiveContains(term) ? candidate : term
        var metadata = parts.count > 1 ? String(parts[1]) : ""
        if headword == term, header.hasPrefix(term) {
            metadata = String(header.dropFirst(term.count))
        }
        metadata = metadata.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|")))
        return (headword, metadata)
    }

    private static func parseNumberedSenses(_ text: String) -> [AppleDictionaryDefinition.Sense] {
        var senses: [AppleDictionaryDefinition.Sense] = []
        var marker: Character?
        var buffer = ""

        func flush() {
            guard let marker else { return }
            let split = splitExamples(buffer)
            let definition = split.definition.trimmingCharacters(in: .whitespacesAndNewlines)
            if !definition.isEmpty || !split.examples.isEmpty {
                let number = senseMarkerSequence.firstIndex(of: marker).map { String($0 + 1) }
                senses.append(.init(number: number, definition: definition, examples: split.examples))
            }
        }

        for character in text {
            if senseMarkers.contains(character) {
                flush()
                marker = character
                buffer = ""
            } else {
                buffer.append(character)
            }
        }
        flush()
        return senses
    }

    private static func splitExamples(_ text: String) -> (definition: String, examples: [String]) {
        var parts: [String] = []
        var buffer = ""
        for character in text {
            if exampleMarkers.contains(character) {
                parts.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                buffer = ""
            } else {
                buffer.append(character)
            }
        }
        parts.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
        let definition = parts.first ?? ""
        return (definition, Array(parts.dropFirst()).filter { !$0.isEmpty })
    }
}

#if os(macOS)
import CoreServices

enum AppleDictionaryService {
    static func definition(for term: String) -> AppleDictionaryDefinition? {
        let value = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let range = CFRange(location: 0, length: (value as NSString).length)
        guard let rawText = DCSCopyTextDefinition(nil, value as CFString, range)?.takeRetainedValue() as String? else {
            return nil
        }
        return AppleDictionaryDefinitionParser.parse(term: value, rawText: rawText)
    }
}
#endif
