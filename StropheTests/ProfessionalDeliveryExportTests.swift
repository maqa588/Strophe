import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import Strophe

final class ProfessionalDeliveryExportTests: XCTestCase {
    @MainActor
    func testTTMLAndIMSC1AreWellFormedAndSignalTheirProfiles() throws {
        let project = makeProject(
            text: "First & line\n第二行",
            start: 1.234,
            end: 3.456
        )
        project.videoSize = CGSize(width: 1_280, height: 720)

        let ttml = try SubtitleDeliveryExporter.export(
            project: project,
            format: .ttml
        )
        let imsc = try SubtitleDeliveryExporter.export(
            project: project,
            format: .imsc1
        )
        let ttmlText = try XCTUnwrap(String(data: ttml, encoding: .utf8))
        let imscText = try XCTUnwrap(String(data: imsc, encoding: .utf8))

        XCTAssertTrue(ttmlText.contains(#"begin="00:00:01.234""#))
        XCTAssertTrue(ttmlText.contains(#"end="00:00:03.456""#))
        XCTAssertTrue(ttmlText.contains("First &amp; line<br/>第二行"))
        XCTAssertTrue(ttmlText.contains(#"tts:extent="1280px 720px""#))
        XCTAssertFalse(ttmlText.contains("contentProfiles="))
        XCTAssertTrue(
            imscText.contains(
                #"ttp:contentProfiles="http://www.w3.org/ns/ttml/profile/imsc1.2/text""#
            )
        )
        XCTAssertTrue(imscText.contains("Strophe IMSC 1.2 Text"))
        assertXMLParses(ttml)
        assertXMLParses(imsc)
    }

    @MainActor
    func testAvidDSCaptionUsesFrameTimecodeBlankRecordsAndUnicode() throws {
        let project = makeProject(
            text: "你好\nAvid",
            start: 1,
            end: 2
        )
        project.videoFrameRate = 25
        project.items.append(
            SubtitleItem(
                text: "Second",
                startTime: 3,
                endTime: 4
            )
        )

        let data = try SubtitleDeliveryExporter.export(
            project: project,
            format: .avidDS
        )

        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = try XCTUnwrap(
            String(data: data.dropFirst(3), encoding: .utf8)
        )
        XCTAssertTrue(
            text.hasPrefix("00:00:01:00 00:00:02:00\r\n你好\nAvid")
        )
        XCTAssertTrue(
            text.contains(
                "\r\n\r\n00:00:03:00 00:00:04:00\r\nSecond"
            )
        )
        XCTAssertTrue(text.hasSuffix("\r\n"))
    }

    @MainActor
    func testFCPXMLUsesProjectRasterAndDropFrameSequenceSettings() throws {
        let project = makeProject(
            text: "Editable title",
            start: 1,
            end: 2
        )
        project.videoSize = CGSize(width: 3_840, height: 2_160)
        project.videoFrameRate = 29.97

        let data = try SubtitleDeliveryExporter.export(
            project: project,
            format: .fcpxml
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains(#"<fcpxml version="1.10">"#))
        XCTAssertTrue(text.contains(#"frameDuration="1001/30000s""#))
        XCTAssertTrue(text.contains(#"width="3840" height="2160""#))
        XCTAssertTrue(text.contains(#"tcFormat="DF""#))
        XCTAssertTrue(text.contains("<title name="))
        assertXMLParses(data)
    }

    @MainActor
    func testSCCHasScenaristHeaderTimecodeAndOddParity608Words() throws {
        let project = makeProject(
            text: "HELLO",
            start: 2,
            end: 4
        )

        let data = try SubtitleDeliveryExporter.export(
            project: project,
            format: .scc
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.hasPrefix("Scenarist_SCC V1.0"))
        XCTAssertTrue(text.contains("C845"))
        XCTAssertTrue(text.contains("4C4C"))
        let payloadWords = text
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .flatMap { line -> [Substring] in
                guard line.contains("\t") else { return [] }
                return Array(
                    line.split(whereSeparator: \.isWhitespace).dropFirst()
                )
            }
        XCTAssertFalse(payloadWords.isEmpty)
        for word in payloadWords {
            XCTAssertEqual(word.count, 4)
            let first = try XCTUnwrap(
                UInt8(word.prefix(2), radix: 16)
            )
            let second = try XCTUnwrap(
                UInt8(word.suffix(2), radix: 16)
            )
            XCTAssertEqual(first.nonzeroBitCount % 2, 1)
            XCTAssertEqual(second.nonzeroBitCount % 2, 1)
        }
    }

    @MainActor
    func testMCCUsesVersion2HeaderAndSupportedTimeCodeRate() throws {
        let project = makeProject(
            text: "CAPTION",
            start: 2,
            end: 4
        )
        project.videoFrameRate = 59.94

        let data = try SubtitleDeliveryExporter.export(
            project: project,
            format: .mcc
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(
            text.hasPrefix("File Format=MacCaption_MCC V2.0")
        )
        XCTAssertTrue(text.contains("Creation Program=Strophe"))
        XCTAssertTrue(text.contains("Time Code Rate=60DF"))
        let dataLine = try XCTUnwrap(
            text.split(whereSeparator: \.isNewline).first {
                $0.contains("\t")
            }
        )
        let fields = dataLine.split(separator: "\t")
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields[0].count, 11)
        XCTAssertEqual(fields[0].filter { $0 == ":" }.count, 3)

        let packet = try decodeMCCBytes(String(fields[1]))
        XCTAssertEqual(Array(packet.prefix(3)), [0x61, 0x01, 0x10])
        let dataCount = Int(packet[2])
        XCTAssertEqual(packet.count, 3 + dataCount + 1)
        let cdp = Array(packet[3..<(3 + dataCount)])
        XCTAssertEqual(Array(cdp.prefix(2)), [0x96, 0x69])
        XCTAssertEqual(Int(cdp[2]), cdp.count)
        XCTAssertEqual(cdp[3], 0x7F)
        XCTAssertEqual(cdp[4], 0x43)
        XCTAssertEqual(cdp[7], 0x72)
        XCTAssertEqual(cdp[8], 0xE1)
        XCTAssertEqual(cdp[9], 0xFC)
        XCTAssertEqual(cdp[12], 0x74)
        XCTAssertEqual(Array(cdp[5...6]), Array(cdp[13...14]))
        XCTAssertEqual(cdp.reduce(0) { ($0 + Int($1)) & 0xFF }, 0)
        let expectedANCChecksum = UInt8(
            truncatingIfNeeded:
                packet.dropLast().reduce(0) { $0 + Int($1) }
        )
        XCTAssertEqual(packet.last, expectedANCChecksum)
    }

    @MainActor
    func testEBUSTLHasGSIAndTech3264TTIFieldLayout() throws {
        let project = makeProject(
            text: "Café\nÄrger",
            start: 1,
            end: 2
        )
        project.videoFrameRate = 25

        let data = try SubtitleDeliveryExporter.export(
            project: project,
            format: .ebuSTL
        )

        XCTAssertEqual(data.count, 1_024 + 128)
        XCTAssertEqual(ascii(data, 0..<3), "850")
        XCTAssertEqual(ascii(data, 3..<11), "STL25.01")
        XCTAssertEqual(ascii(data, 238..<243), "00001")
        XCTAssertEqual(ascii(data, 243..<248), "00001")

        let tti = 1_024
        XCTAssertEqual(data[tti], 0) // subtitle group
        XCTAssertEqual(data[tti + 1], 1) // subtitle number, little endian
        XCTAssertEqual(data[tti + 2], 0)
        XCTAssertEqual(data[tti + 3], 0xFF) // final extension block
        XCTAssertEqual(
            Array(data[(tti + 5)..<(tti + 9)]),
            [0, 0, 1, 0]
        )
        XCTAssertEqual(
            Array(data[(tti + 9)..<(tti + 13)]),
            [0, 0, 2, 0]
        )
        XCTAssertTrue(
            data[(tti + 16)..<(tti + 128)].contains(0x8A),
            "EBU STL line break must be encoded as 0x8A."
        )
        XCTAssertTrue(
            data[(tti + 16)..<(tti + 128)].contains(0x8F),
            "EBU STL text field must be terminated/padded with 0x8F."
        )
        let textField = Array(data[(tti + 16)..<(tti + 128)])
        XCTAssertTrue(
            zip(textField, textField.dropFirst()).contains {
                $0.0 == 0xC2 && $0.1 == 0x65
            },
            "ISO 6937 must encode é as floating acute accent + e."
        )
        XCTAssertTrue(
            zip(textField, textField.dropFirst()).contains {
                $0.0 == 0xC8 && $0.1 == 0x41
            },
            "ISO 6937 must encode Ä as floating diaeresis + A."
        )
    }

    @MainActor
    func testPremiereGraphicsPackageContainsParseableXMLAndFullCanvasPNG()
        throws {
        let project = makeProject(
            text: "Premiere",
            start: 0,
            end: 0.1
        )
        project.videoSize = CGSize(width: 320, height: 180)
        project.videoFrameRate = 24

        let archive = try SubtitleDeliveryExporter.export(
            project: project,
            format: .premiereXMLPNG
        )
        let entries = try unzipStoredEntries(archive)
        let xml = try XCTUnwrap(entries["sequence.xml"])
        let png = try XCTUnwrap(entries["Media/subtitle-00001.png"])

        XCTAssertNotNil(entries["README.txt"])
        assertXMLParses(xml)
        let xmlText = try XCTUnwrap(String(data: xml, encoding: .utf8))
        XCTAssertTrue(xmlText.contains("<width>320</width>"))
        XCTAssertTrue(xmlText.contains("<height>180</height>"))
        XCTAssertTrue(xmlText.contains("<alphatype>straight</alphatype>"))
        assertPNG(png, width: 320, height: 180)
    }

    @MainActor
    func testAfterEffectsPackageContainsFrameSequenceManifestAndImporter()
        throws {
        let project = makeProject(
            text: "歌",
            start: 0,
            end: 0.09
        )
        project.videoSize = CGSize(width: 320, height: 180)
        project.videoFrameRate = 24
        project.items[0].karaoke = try XCTUnwrap(
            KaraokeProgram.evenlyTimed(text: "歌", duration: 0.09)
        )

        let archive = try SubtitleDeliveryExporter.export(
            project: project,
            format: .afterEffectsPNGSequence
        )
        let entries = try unzipStoredEntries(archive)
        let manifestData = try XCTUnwrap(entries["manifest.json"])
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: manifestData)
                as? [String: Any]
        )
        let cues = try XCTUnwrap(manifest["cues"] as? [[String: Any]])
        let cue = try XCTUnwrap(cues.first)
        let frameCount = try XCTUnwrap(cue["frameCount"] as? Int)

        XCTAssertEqual(manifest["width"] as? Int, 320)
        XCTAssertEqual(manifest["height"] as? Int, 180)
        XCTAssertEqual(cue["hasKaraoke"] as? Bool, true)
        XCTAssertGreaterThanOrEqual(frameCount, 2)
        XCTAssertNotNil(entries["import-strophe.jsx"])
        XCTAssertNotNil(entries["README.txt"])
        let pngEntries = entries.filter {
            $0.key.hasPrefix("PNG/cue-00001/frame-")
                && $0.key.hasSuffix(".png")
        }
        XCTAssertEqual(pngEntries.count, frameCount)
        for png in pngEntries.values {
            assertPNG(png, width: 320, height: 180)
        }
    }

    func testDropFrameTimecodeSkipsMinuteFrameNumbers() {
        XCTAssertEqual(
            ProfessionalFrameRate.ntsc2997.timecode(forFrame: 1_800),
            "00:01:00;02"
        )
        XCTAssertEqual(
            ProfessionalFrameRate.ntsc2997.timecode(forFrame: 17_982),
            "00:10:00;00"
        )
    }

    #if os(macOS)
    @MainActor
    func testClosedCaptionSidecarsAreAcceptedByInstalledFFprobe() throws {
        let candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]
        guard let ffprobe = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw XCTSkip("ffprobe is not installed on this test host.")
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Strophe-ProfessionalDelivery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let project = makeProject(
            text: "BROADCAST",
            start: 1,
            end: 2
        )
        project.videoFrameRate = 29.97
        for format in [
            SubtitleDeliveryFormat.scc,
            .mcc
        ] {
            let url = folder.appendingPathComponent(
                "captions.\(format.fileExtension)"
            )
            try SubtitleDeliveryExporter.export(
                project: project,
                format: format
            ).write(to: url)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobe)
            process.arguments = [
                "-v", "error",
                "-show_entries", "stream=codec_name,codec_type",
                "-of", "default=noprint_wrappers=1",
                url.path
            ]
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            process.waitUntilExit()

            let stderr = String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            let stdout = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            XCTAssertEqual(
                process.terminationStatus,
                0,
                "\(format) was rejected by ffprobe: \(stderr)"
            )
            XCTAssertTrue(
                stdout.contains("codec_type="),
                "\(format) did not expose a recognized stream: \(stdout)"
            )
        }
    }
    #endif

    @MainActor
    func testProfessionalFormatsRejectEmptyProjects() {
        let project = SubtitleProject()
        for format in [
            SubtitleDeliveryFormat.ttml,
            .imsc1,
            .avidDS,
            .scc,
            .mcc,
            .ebuSTL,
            .premiereXMLPNG,
            .afterEffectsPNGSequence
        ] {
            XCTAssertThrowsError(
                try SubtitleDeliveryExporter.export(
                    project: project,
                    format: format
                ),
                "\(format) should reject an empty project."
            )
        }
    }

    @MainActor
    private func makeProject(
        text: String,
        start: Double,
        end: Double
    ) -> SubtitleProject {
        let project = SubtitleProject()
        project.items = [
            SubtitleItem(
                text: text,
                startTime: start,
                endTime: end,
                languageCode: "zh-Hans"
            )
        ]
        return project
    }

    private func assertXMLParses(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let parser = XMLParser(data: data)
        XCTAssertTrue(
            parser.parse(),
            parser.parserError?.localizedDescription ?? "Invalid XML",
            file: file,
            line: line
        )
    }

    private func assertPNG(
        _ data: Data,
        width: Int,
        height: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            Array(data.prefix(8)),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            file: file,
            line: line
        )
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            nil
        ),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("Could not decode generated PNG.", file: file, line: line)
            return
        }
        XCTAssertEqual(image.width, width, file: file, line: line)
        XCTAssertEqual(image.height, height, file: file, line: line)
        XCTAssertEqual(
            image.alphaInfo,
            .last,
            file: file,
            line: line
        )
    }

    private func decodeMCCBytes(_ encoded: String) throws -> [UInt8] {
        enum MCCDecodeError: Error {
            case invalidCharacter(Character)
            case invalidHex
        }

        let characters = Array(encoded)
        var bytes: [UInt8] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "G"..."O":
                let repetitions = Int(
                    character.asciiValue! - Character("G").asciiValue! + 1
                )
                for _ in 0..<repetitions {
                    bytes += [0xFA, 0, 0]
                }
                index += 1
            case "P"..."R":
                let first = UInt8(
                    0xFB
                        + (
                            character.asciiValue!
                                - Character("P").asciiValue!
                        )
                )
                bytes += [first, 0x80, 0x80]
                index += 1
            case "S":
                bytes += [0x96, 0x69]
                index += 1
            case "T":
                bytes += [0x61, 0x01]
                index += 1
            case "U":
                bytes += [0xE1, 0, 0, 0]
                index += 1
            case "Z":
                bytes.append(0)
                index += 1
            default:
                guard index + 1 < characters.count else {
                    throw MCCDecodeError.invalidCharacter(character)
                }
                let hex = String(characters[index...index + 1])
                guard let byte = UInt8(hex, radix: 16) else {
                    throw MCCDecodeError.invalidHex
                }
                bytes.append(byte)
                index += 2
            }
        }
        return bytes
    }

    private func ascii(_ data: Data, _ range: Range<Int>) -> String {
        String(decoding: data[range], as: UTF8.self)
    }

    /// `StoredZIPWriter` deliberately uses the ZIP "store" method. Parsing
    /// local headers here independently verifies names, sizes and payloads.
    private func unzipStoredEntries(
        _ data: Data
    ) throws -> [String: Data] {
        enum ZIPTestError: Error {
            case malformed
            case compressedEntry
        }

        func uint16(_ offset: Int) throws -> Int {
            guard offset + 2 <= data.count else {
                throw ZIPTestError.malformed
            }
            return Int(data[offset])
                | (Int(data[offset + 1]) << 8)
        }

        func uint32(_ offset: Int) throws -> UInt32 {
            guard offset + 4 <= data.count else {
                throw ZIPTestError.malformed
            }
            return UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }

        var result: [String: Data] = [:]
        var offset = 0
        while offset + 4 <= data.count {
            let signature = try uint32(offset)
            if signature == 0x0201_4B50 || signature == 0x0605_4B50 {
                break
            }
            guard signature == 0x0403_4B50 else {
                throw ZIPTestError.malformed
            }
            let method = try uint16(offset + 8)
            guard method == 0 else {
                throw ZIPTestError.compressedEntry
            }
            let compressedSize = Int(try uint32(offset + 18))
            let filenameLength = try uint16(offset + 26)
            let extraLength = try uint16(offset + 28)
            let filenameStart = offset + 30
            let payloadStart = filenameStart + filenameLength + extraLength
            let payloadEnd = payloadStart + compressedSize
            guard payloadEnd <= data.count else {
                throw ZIPTestError.malformed
            }
            let name = String(
                decoding: data[filenameStart..<(filenameStart + filenameLength)],
                as: UTF8.self
            )
            result[name] = Data(data[payloadStart..<payloadEnd])
            offset = payloadEnd
        }
        return result
    }
}
