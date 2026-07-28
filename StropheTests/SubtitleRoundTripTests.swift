import XCTest
@testable import Strophe

final class SubtitleRoundTripTests: XCTestCase {
    @MainActor
    func testASSRoundTripPreservesStylesUnknownFieldsAndInlineTags() throws {
        let fixture = try fixture(named: "golden", extension: "ass")
        let first = ASSProcessor().parseDocument(text: fixture, sourceFileName: "golden.ass")

        XCTAssertEqual(first.document.blocks.count, 2)
        XCTAssertEqual(first.document.source?.ass?.styles.map(\.name), ["Main", "Translation"])
        XCTAssertEqual(first.document.source?.ass?.playResolutionX, 1_920)
        XCTAssertEqual(first.document.blocks[0].text, "Hello, brave\nworld")
        XCTAssertEqual(
            first.document.blocks[0].interchangeMetadata?.ass?.fields["customfield"],
            "custom-data"
        )

        let exported = ASSProcessor().generate(document: first.document)
        XCTAssertTrue(exported.contains("X-Strophe-Unknown: keep-me"))
        XCTAssertTrue(exported.contains("Comment: 0,0:00:00.00"))
        XCTAssertTrue(exported.contains(#"{\an8\blur1.5\foo(17)}Hello, brave\Nworld"#))
        XCTAssertTrue(exported.contains("Style: Translation,Helvetica Neue,46"))

        let reparsed = ASSProcessor().parseDocument(text: exported, sourceFileName: nil)
        let reexported = ASSProcessor().generate(document: reparsed.document)
        XCTAssertEqual(reexported, exported, "ASS serialization must be stable after one normalization")

        var edited = first.document
        edited.blocks[0].text = "Edited\nvisible text"
        let editedExport = ASSProcessor().generate(document: edited)
        XCTAssertTrue(
            editedExport.contains(#"{\an8\blur1.5\foo(17)}Edited\Nvisible text"#),
            "Editing visible text must not discard unknown override tags"
        )
    }

    @MainActor
    func testSRTRoundTripPreservesIdentifiersAndTimingSuffix() throws {
        let fixture = try fixture(named: "golden", extension: "srt")
        let first = SRTProcessor().parseDocument(text: fixture, sourceFileName: "golden.srt")

        XCTAssertEqual(first.document.blocks.count, 2)
        XCTAssertEqual(first.document.blocks[0].interchangeMetadata?.srt?.identifier, "cue-A")
        XCTAssertEqual(
            first.document.blocks[0].interchangeMetadata?.srt?.timingSuffix,
            "X1:40 X2:600 Y1:20 Y2:80"
        )

        assertStableRoundTrip(
            document: first.document,
            generate: SRTProcessor().generate,
            parse: { SRTProcessor().parseDocument(text: $0, sourceFileName: nil).document }
        )
    }

    @MainActor
    func testWebVTTRoundTripPreservesHeaderBlocksCueSettingsAndMarkup() throws {
        let fixture = try fixture(named: "golden", extension: "vtt")
        let first = WebVTTProcessor().parseDocument(text: fixture, sourceFileName: "golden.vtt")

        XCTAssertEqual(first.document.blocks.count, 2)
        XCTAssertEqual(first.document.blocks[0].text, "Hello, brave world.")
        XCTAssertEqual(first.document.blocks[0].interchangeMetadata?.webVTT?.identifier, "speaker-1")
        XCTAssertTrue(
            first.document.blocks[0].interchangeMetadata?.webVTT?.settings.contains("region:bottom")
                == true
        )

        let exported = WebVTTProcessor().generate(document: first.document)
        XCTAssertTrue(exported.contains("::cue(.green) { color: lime; }"))
        XCTAssertTrue(exported.contains("NOTE editor metadata"))
        XCTAssertTrue(exported.contains("<v Alice><c.green>Hello</c>, <i>brave</i> world.</v>"))

        let reparsed = WebVTTProcessor().parseDocument(text: exported, sourceFileName: nil)
        XCTAssertEqual(WebVTTProcessor().generate(document: reparsed.document), exported)
    }

    @MainActor
    func testLRCRoundTripPreservesMetadataAndTimestampPrecision() throws {
        let fixture = try fixture(named: "golden", extension: "lrc")
        let first = LRCProcessor().parseDocument(text: fixture, sourceFileName: "golden.lrc")

        XCTAssertEqual(first.document.blocks.count, 4)
        XCTAssertTrue(first.document.source?.lrc?.metadataLines.contains("[x-custom:keep-me]") == true)

        let exported = LRCProcessor().generate(document: first.document)
        XCTAssertTrue(exported.contains("[00:01.230]第一行"))
        XCTAssertTrue(exported.contains("[00:07.125]重复时间标签"))
        XCTAssertTrue(exported.contains("[12:34.5]长时间歌词"))

        let reparsed = LRCProcessor().parseDocument(text: exported, sourceFileName: nil)
        XCTAssertEqual(LRCProcessor().generate(document: reparsed.document), exported)
    }

    @MainActor
    private func assertStableRoundTrip(
        document: SubtitleDocument,
        generate: (SubtitleDocument) -> String,
        parse: (String) -> SubtitleDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let first = generate(document)
        let second = generate(parse(first))
        XCTAssertEqual(second, first, file: file, line: line)
    }

    private func fixture(named name: String, extension pathExtension: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension(pathExtension)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
