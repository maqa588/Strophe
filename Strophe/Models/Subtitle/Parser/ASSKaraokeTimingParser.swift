import Foundation

/// Converts standard ASS `\k`, `\K`, `\kf` and `\ko` tags into Strophe's
/// renderer-independent Karaoke program while the lossless ASS payload remains
/// available for round-trip export.
nonisolated enum ASSKaraokeTimingParser {
    private struct Marker {
        let offset: Int
        let duration: Double
        let sweep: Bool
    }

    static func program(from styledText: PreservedStyledText) -> KaraokeProgram? {
        guard styledText.dialect == .ass else { return nil }
        let pattern = #"\\(kf|ko|k|K)(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        var markers: [Marker] = []
        for token in styledText.tokens {
            let range = NSRange(token.rawValue.startIndex..<token.rawValue.endIndex, in: token.rawValue)
            for match in regex.matches(in: token.rawValue, range: range) {
                guard let kindRange = Range(match.range(at: 1), in: token.rawValue),
                      let durationRange = Range(match.range(at: 2), in: token.rawValue),
                      let centiseconds = Double(token.rawValue[durationRange]) else { continue }
                let kind = String(token.rawValue[kindRange]).lowercased()
                markers.append(
                    Marker(
                        offset: token.characterOffset,
                        duration: centiseconds / 100,
                        sweep: kind == "kf"
                    )
                )
            }
        }

        guard !markers.isEmpty else { return nil }
        let textCharacters = Array(styledText.plainTextAtImport)
        var elapsed = 0.0
        var units: [KaraokeTimingUnit] = []

        for index in markers.indices {
            let marker = markers[index]
            let nextOffset = index + 1 < markers.count
                ? markers[index + 1].offset
                : textCharacters.count
            let start = min(max(0, marker.offset), textCharacters.count)
            let end = min(max(start, nextOffset), textCharacters.count)
            guard end > start else {
                elapsed += marker.duration
                continue
            }
            units.append(
                KaraokeTimingUnit(
                    text: String(textCharacters[start..<end]),
                    characterStart: start,
                    characterLength: end - start,
                    startOffset: elapsed,
                    endOffset: elapsed + marker.duration,
                    source: .ass
                )
            )
            elapsed += marker.duration
        }

        guard !units.isEmpty else { return nil }
        let usesSweep = markers.contains(where: \.sweep)
        return KaraokeProgram(
            textSnapshot: styledText.plainTextAtImport,
            units: units,
            template: usesSweep ? .classicSweep : .classicStep,
            isEnabled: true
        )
    }
}
