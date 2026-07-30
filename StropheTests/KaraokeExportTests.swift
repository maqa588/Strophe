import Foundation
import XCTest
@testable import Strophe

final class KaraokeExportTests: XCTestCase {
    @MainActor
    func testASSExportCompilesCurrentKaraokeTimingAndColors() throws {
        let program = KaraokeProgram(
            textSnapshot: "君の",
            units: [
                KaraokeTimingUnit(
                    text: "君",
                    characterStart: 0,
                    characterLength: 1,
                    startOffset: 0.1,
                    endOffset: 0.3,
                    source: .manual
                ),
                KaraokeTimingUnit(
                    text: "の",
                    characterStart: 1,
                    characterLength: 1,
                    startOffset: 0.5,
                    endOffset: 1,
                    source: .manual
                )
            ],
            template: KaraokeTemplateConfiguration(
                preset: .classicSweep,
                revealMode: .sweep,
                inactiveColorHex: "#112233FF",
                activeColorHex: "#AABBCC80",
                popScale: 1,
                glowRadius: 0,
                glowIntensity: 0
            )
        )
        let item = SubtitleItem(
            text: "君の",
            startTime: 2,
            endTime: 3,
            karaoke: program
        )
        let project = SubtitleProject()
        project.items = [item]

        let exported = SubtitleEngine.generate(
            project.subtitleDocument(for: .ass)
        )

        XCTAssertTrue(exported.contains(#"\1c&HCCBBAA&"#))
        XCTAssertTrue(exported.contains(#"\2c&H332211&"#))
        XCTAssertTrue(exported.contains(#"\1a&H7F&"#))
        XCTAssertTrue(exported.contains(#"{\k10}{\kf20}君"#))
        XCTAssertTrue(exported.contains(#"{\k20}{\kf50}の"#))

        let reparsed = ASSProcessor().parseDocument(
            text: exported,
            sourceFileName: nil
        )
        let styledText = try XCTUnwrap(
            reparsed.document.blocks.first?.interchangeMetadata?.ass?.styledText
        )
        let reparsedProgram = try XCTUnwrap(
            ASSKaraokeTimingParser.program(from: styledText)
        )
        XCTAssertEqual(reparsedProgram.units.count, 2)
        XCTAssertEqual(
            reparsedProgram.units[0].startOffset,
            0.1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            reparsedProgram.units[0].endOffset,
            0.3,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            reparsedProgram.units[1].startOffset,
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            reparsedProgram.units[1].endOffset,
            1,
            accuracy: 0.000_001
        )
    }

    @MainActor
    func testASSExportRemovesImportedKaraokeTagsWhenDisabled() throws {
        let parsed = ASSProcessor().parseDocument(
            text: """
            [Script Info]
            ScriptType: v4.00+
            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,{\\an8\\k20}君{\\kf80}の
            """,
            sourceFileName: "karaoke.ass"
        )
        let project = SubtitleProject()
        project.importSubtitleDocument(parsed)
        let item = try XCTUnwrap(project.items.first)
        XCTAssertNotNil(item.activeKaraoke)

        project.disableKaraoke(id: item.id)
        let exported = SubtitleEngine.generate(
            project.subtitleDocument(for: .ass)
        )

        XCTAssertFalse(exported.contains(#"\k20"#))
        XCTAssertFalse(exported.contains(#"\kf80"#))
        XCTAssertTrue(exported.contains(#"{\an8}君の"#))
    }

    @MainActor
    func testASSExportReplacesImportedTagsWithEditedTiming() throws {
        let parsed = ASSProcessor().parseDocument(
            text: """
            [Script Info]
            ScriptType: v4.00+
            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,{\\an8\\k20}君{\\kf80}の
            """,
            sourceFileName: "karaoke.ass"
        )
        let project = SubtitleProject()
        project.importSubtitleDocument(parsed)
        project.items[0].karaoke = KaraokeProgram(
            textSnapshot: "君の",
            units: [
                KaraokeTimingUnit(
                    text: "君",
                    characterStart: 0,
                    characterLength: 1,
                    startOffset: 0,
                    endOffset: 0.4,
                    source: .manual
                ),
                KaraokeTimingUnit(
                    text: "の",
                    characterStart: 1,
                    characterLength: 1,
                    startOffset: 0.4,
                    endOffset: 1,
                    source: .manual
                )
            ],
            template: .classicSweep
        )

        let exported = SubtitleEngine.generate(
            project.subtitleDocument(for: .ass)
        )

        XCTAssertFalse(exported.contains(#"\k20"#))
        XCTAssertFalse(exported.contains(#"\kf80"#))
        XCTAssertTrue(exported.contains(#"{\an8}"#))
        XCTAssertTrue(exported.contains(#"{\kf40}君{\kf60}の"#))
    }

    @MainActor
    func testASSParserWriterWithoutProjectStateRemainsLossless() {
        let source = """
        [Script Info]
        ScriptType: v4.00+
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,{\\k20}君{\\kf80}の
        """
        let parsed = ASSProcessor().parseDocument(
            text: source,
            sourceFileName: nil
        )

        let exported = ASSProcessor().generate(document: parsed.document)

        XCTAssertTrue(exported.contains(#"{\k20}君{\kf80}の"#))
    }

    @MainActor
    func testFCPXMLExportsEditableKaraokeStateTitles() throws {
        let program = try XCTUnwrap(
            KaraokeProgram.evenlyTimed(
                text: "君の",
                duration: 2,
                template: .classicStep
            )
        )
        let item = SubtitleItem(
            text: "君の",
            startTime: 10,
            endTime: 12,
            trackIndex: 2,
            karaoke: program
        )
        let project = SubtitleProject()
        project.items = [item]

        let data = try SubtitleDeliveryExporter.export(
            project: project,
            format: .fcpxml
        )
        let xml = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(xml.occurrences(of: "<title name="), 2)
        XCTAssertTrue(xml.contains(#"lane="3""#))
        XCTAssertTrue(xml.contains(#"offset="10000000/1000000s""#))
        XCTAssertTrue(xml.contains(#"offset="11000000/1000000s""#))
        XCTAssertTrue(xml.contains(#"<text-style ref="ts1a1">君</text-style>"#))
        XCTAssertTrue(xml.contains(#"<text-style ref="ts1i1">の</text-style>"#))
        XCTAssertTrue(xml.contains(#"<text-style ref="ts1a2">君の</text-style>"#))
        XCTAssertFalse(
            xml.contains("<metadata>"),
            "DaVinci Resolve rejects metadata as a child of FCPXML title."
        )
        let parser = XMLParser(data: data)
        XCTAssertTrue(
            parser.parse(),
            parser.parserError?.localizedDescription ?? "Invalid FCPXML"
        )
    }

    @MainActor
    func testFCPXMLDisabledKaraokeExportsOneStaticTitle() throws {
        var program = try XCTUnwrap(
            KaraokeProgram.evenlyTimed(text: "静态", duration: 2)
        )
        program.isEnabled = false
        let project = SubtitleProject()
        project.items = [
            SubtitleItem(
                text: "静态",
                startTime: 0,
                endTime: 2,
                karaoke: program
            )
        ]

        let data = try SubtitleDeliveryExporter.export(
            project: project,
            format: .fcpxml
        )
        let xml = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(xml.occurrences(of: "<title name="), 1)
        XCTAssertFalse(xml.contains("com.strophe.karaoke"))
    }
}

private extension String {
    func occurrences(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return components(separatedBy: needle).count - 1
    }
}
