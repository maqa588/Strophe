//
//  SubtitleDeliveryExporter.swift
//  Strophe
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum SubtitleDeliveryFormat: String, CaseIterable, Identifiable {
    case csv
    case excel
    case fcpxml
    case ttml
    case imsc1
    case avidDS
    case scc
    case mcc
    case ebuSTL
    case premiereXMLPNG
    case afterEffectsPNGSequence

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .excel: return "xlsx"
        case .fcpxml: return "fcpxml"
        case .ttml, .imsc1: return "ttml"
        case .avidDS: return "txt"
        case .scc: return "scc"
        case .mcc: return "mcc"
        case .ebuSTL: return "stl"
        case .premiereXMLPNG, .afterEffectsPNGSequence: return "zip"
        }
    }

    var contentType: UTType {
        switch self {
        case .csv:
            return .commaSeparatedText
        case .excel:
            return .stropheExcelWorkbook
        case .fcpxml:
            return .stropheFCPXML
        case .ttml, .imsc1:
            return .stropheTTML
        case .avidDS:
            return .plainText
        case .scc:
            return .stropheSCC
        case .mcc:
            return .stropheMCC
        case .ebuSTL:
            return .stropheEBUSTL
        case .premiereXMLPNG, .afterEffectsPNGSequence:
            return .zip
        }
    }

    var filenameQualifier: String {
        switch self {
        case .csv: return "data"
        case .excel: return "data"
        case .fcpxml: return "final-cut"
        case .ttml: return "ttml"
        case .imsc1: return "imsc1"
        case .avidDS: return "avid-ds"
        case .scc: return "cea-608"
        case .mcc: return "cea-708"
        case .ebuSTL: return "ebu-stl"
        case .premiereXMLPNG: return "premiere-graphics"
        case .afterEffectsPNGSequence: return "after-effects-png"
        }
    }
}

extension UTType {
    static nonisolated let stropheExcelWorkbook =
        UTType(importedAs: "org.openxmlformats.spreadsheetml.sheet")
    static nonisolated let stropheFCPXML =
        UTType(importedAs: "com.apple.final-cut-pro.xml")
    static nonisolated let stropheTTML =
        UTType(filenameExtension: "ttml", conformingTo: .xml)
        ?? UTType(importedAs: "application.ttml+xml")
    static nonisolated let stropheSCC =
        UTType(filenameExtension: "scc", conformingTo: .plainText)
        ?? UTType(importedAs: "com.scenarist.closed-caption")
    static nonisolated let stropheMCC =
        UTType(filenameExtension: "mcc", conformingTo: .plainText)
        ?? UTType(importedAs: "com.telestream.maccaption")
    static nonisolated let stropheEBUSTL =
        UTType(filenameExtension: "stl", conformingTo: .data)
        ?? UTType(importedAs: "org.ebu.tech3264")
}

struct BinaryDeliveryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.item, .content, .data] }
    static var writableContentTypes: [UTType] {
        [
            .item,
            .content,
            .data,
            .audio,
            .movie,
            .video,
            .commaSeparatedText,
            .xml,
            .zip,
            .plainText,
            .stropheExcelWorkbook,
            .stropheFCPXML,
            .stropheTTML,
            .stropheSCC,
            .stropheMCC,
            .stropheEBUSTL
        ]
    }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum SubtitleDeliveryExporter {
    @MainActor
    static func export(
        project: SubtitleProject,
        format: SubtitleDeliveryFormat
    ) throws -> Data {
        switch format {
        case .csv:
            return csv(project: project)
        case .excel:
            return excel(project: project)
        case .fcpxml:
            return fcpxml(project: project)
        case .ttml:
            return try ProfessionalSubtitleDeliveryExporter.ttml(
                project: project,
                profile: .ttml
            )
        case .imsc1:
            return try ProfessionalSubtitleDeliveryExporter.ttml(
                project: project,
                profile: .imsc1
            )
        case .avidDS:
            return try ProfessionalSubtitleDeliveryExporter.avidDS(project: project)
        case .scc:
            return try ProfessionalSubtitleDeliveryExporter.closedCaption(
                project: project,
                format: .scc
            )
        case .mcc:
            return try ProfessionalSubtitleDeliveryExporter.closedCaption(
                project: project,
                format: .mcc
            )
        case .ebuSTL:
            return try ProfessionalSubtitleDeliveryExporter.ebuSTL(project: project)
        case .premiereXMLPNG:
            return try SubtitleGraphicsPackageExporter.premiereXMLPNG(
                project: project
            )
        case .afterEffectsPNGSequence:
            return try SubtitleGraphicsPackageExporter.afterEffectsPNGSequence(
                project: project
            )
        }
    }

    @MainActor
    private static func tabularRows(project: SubtitleProject) -> [[String]] {
        let store = StyleAndGroupStore.shared
        let header = [
            "Index", "Start", "End", "Duration", "Text",
            "Group", "Language", "Style", "Track", "Layer"
        ]
        let rows = project.items
            .sorted(by: project.stableSubtitleSort)
            .enumerated()
            .map { index, item -> [String] in
                let start = item.startTime.map(tabularTime) ?? ""
                let end = item.endTime.map(tabularTime) ?? ""
                let duration: String
                if let startTime = item.startTime, let endTime = item.endTime {
                    duration = String(format: "%.3f", max(0, endTime - startTime))
                } else {
                    duration = ""
                }
                let group = store.group(id: item.groupID)
                let style = store.style(id: item.styleID)
                    ?? store.defaultStyle(for: group)
                return [
                    String(index + 1),
                    start,
                    end,
                    duration,
                    item.text,
                    group?.name ?? "",
                    item.languageCode ?? "",
                    style?.name ?? "",
                    String(item.trackIndex),
                    String(item.layer)
                ]
            }
        return [header] + rows
    }

    @MainActor
    private static func csv(project: SubtitleProject) -> Data {
        let text = tabularRows(project: project)
            .map { $0.map(csvField).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
        // UTF-8 BOM keeps CJK text correct in older Excel versions.
        return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    }

    @MainActor
    private static func excel(project: SubtitleProject) -> Data {
        let rows = tabularRows(project: project)
        var sheetRows = ""
        for (rowIndex, row) in rows.enumerated() {
            let cells = row.enumerated().map { columnIndex, value -> String in
                let reference = "\(columnName(columnIndex + 1))\(rowIndex + 1)"
                if rowIndex > 0,
                   [0, 3, 8, 9].contains(columnIndex),
                   Double(value) != nil {
                    return #"<c r="\#(reference)"><v>\#(xmlEscape(value))</v></c>"#
                }
                return #"<c r="\#(reference)" t="inlineStr"><is><t xml:space="preserve">\#(xmlEscape(value))</t></is></c>"#
            }
            .joined()
            sheetRows += #"<row r="\#(rowIndex + 1)">\#(cells)</row>"#
        }

        let sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <cols>
            <col min="1" max="1" width="8" customWidth="1"/>
            <col min="2" max="4" width="15" customWidth="1"/>
            <col min="5" max="5" width="64" customWidth="1"/>
            <col min="6" max="10" width="18" customWidth="1"/>
          </cols>
          <sheetData>\(sheetRows)</sheetData>
          <autoFilter ref="A1:J\(max(1, rows.count))"/>
        </worksheet>
        """
        let entries: [StoredZIPEntry] = [
            StoredZIPEntry(
                path: "[Content_Types].xml",
                data: Data("""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
                  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
                  <Default Extension="xml" ContentType="application/xml"/>
                  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
                  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
                </Types>
                """.utf8)
            ),
            StoredZIPEntry(
                path: "_rels/.rels",
                data: Data("""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
                </Relationships>
                """.utf8)
            ),
            StoredZIPEntry(
                path: "xl/workbook.xml",
                data: Data("""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                  <sheets><sheet name="Subtitles" sheetId="1" r:id="rId1"/></sheets>
                </workbook>
                """.utf8)
            ),
            StoredZIPEntry(
                path: "xl/_rels/workbook.xml.rels",
                data: Data("""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
                </Relationships>
                """.utf8)
            ),
            StoredZIPEntry(path: "xl/worksheets/sheet1.xml", data: Data(sheet.utf8))
        ]
        return StoredZIPWriter.archive(entries)
    }

    @MainActor
    private static func fcpxml(project: SubtitleProject) -> Data {
        let store = StyleAndGroupStore.shared
        let cues = project.items
            .filter { item in
                guard let start = item.startTime,
                      let end = item.endTime,
                      start.isFinite,
                      end.isFinite,
                      end > start,
                      !item.isHidden else {
                    return false
                }
                guard let group = store.group(id: item.groupID) else {
                    return true
                }
                switch group.exportPolicy {
                case .includeInAllExports, .textOnly:
                    return true
                case .burnedInOnly, .excludeByDefault, .referenceOnly:
                    return false
                }
            }
            .sorted(by: project.stableSubtitleSort)
        let duration = max(cues.compactMap(\.endTime).max() ?? 1, 1)
        let canvasSize = ProfessionalSubtitleDeliveryExporter
            .resolvedCanvasSize(project.videoSize)
        let frameRate = ProfessionalFrameRate.nearest(
            to: project.videoFrameRate
        )
        var titles = ""
        for (index, cue) in cues.enumerated() {
            guard let start = cue.startTime, let end = cue.endTime else { continue }
            let cueDuration = max(0.001, end - start)
            if let program = cue.activeKaraoke?.reconciled(
                to: cue.text,
                cueDuration: cueDuration
            ) {
                titles += fcpxmlKaraokeTitles(
                    cue: cue,
                    program: program,
                    cueIndex: index,
                    startTime: start,
                    duration: cueDuration
                )
            } else {
                titles += fcpxmlStaticTitle(
                    cue: cue,
                    cueIndex: index,
                    startTime: start,
                    duration: cueDuration
                )
            }
        }
        let projectName = project.documentDisplayName.isEmpty
            ? "Strophe Subtitles"
            : project.documentDisplayName
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
          <resources>
            <format id="r1" name="FFVideoFormat\(Int(canvasSize.height))p\(frameRate.nominalFramesPerSecond)" frameDuration="\(frameDuration(frameRate.value))" width="\(Int(canvasSize.width))" height="\(Int(canvasSize.height))" colorSpace="1-1-1 (Rec. 709)"/>
            <effect id="r2" name="Basic Title" uid=".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"/>
          </resources>
          <library>
            <event name="Strophe">
              <project name="\(xmlEscape(projectName))">
                <sequence format="r1" duration="\(fcpxTime(duration))" tcStart="0s" tcFormat="\(frameRate.isDropFrame ? "DF" : "NDF")" audioLayout="stereo" audioRate="48k">
                  <spine>
                    <gap name="Subtitles" offset="0s" start="0s" duration="\(fcpxTime(duration))">
        \(titles)            </gap>
                  </spine>
                </sequence>
              </project>
            </event>
          </library>
        </fcpxml>
        """
        return Data(xml.utf8)
    }

    private static func fcpxmlStaticTitle(
        cue: SubtitleItem,
        cueIndex: Int,
        startTime: Double,
        duration: Double
    ) -> String {
        let styleID = "ts\(cueIndex + 1)"
        return """
            <title name="\(xmlEscape(cue.text.prefix(40).description))" lane="\(fcpxLane(cue))" offset="\(fcpxTime(startTime))" ref="r2" start="0s" duration="\(fcpxTime(duration))">
              <text><text-style ref="\(styleID)">\(xmlEscape(cue.text))</text-style></text>
              <text-style-def id="\(styleID)"><text-style font="Helvetica" fontSize="48" fontColor="1 1 1 1" alignment="center"/></text-style-def>
            </title>

        """
    }

    /// FCPXML's built-in Basic Title has no portable per-glyph sweep mask.
    /// Export a sequence of editable full-line attributed titles instead:
    /// every Karaoke boundary starts a new title whose completed ranges use the
    /// active color. This preserves exact Step timing and gives Sweep/Pop/Glow
    /// projects a deterministic, editable Step fallback.
    private static func fcpxmlKaraokeTitles(
        cue: SubtitleItem,
        program: KaraokeProgram,
        cueIndex: Int,
        startTime: Double,
        duration: Double
    ) -> String {
        let units = program.units.sorted {
            $0.characterStart == $1.characterStart
                ? $0.startOffset < $1.startOffset
                : $0.characterStart < $1.characterStart
        }
        let durationMicroseconds = max(1, fcpxMicroseconds(duration))
        let startMicroseconds = fcpxMicroseconds(startTime)
        var boundaries = [0, durationMicroseconds]
        boundaries.append(contentsOf: units.map {
            min(
                max(0, fcpxMicroseconds($0.startOffset)),
                durationMicroseconds
            )
        })
        boundaries = Array(Set(boundaries))
            .sorted()

        var result = ""
        for segmentIndex in 0..<max(0, boundaries.count - 1) {
            let localStart = boundaries[segmentIndex]
            let localEnd = boundaries[segmentIndex + 1]
            guard localEnd > localStart else { continue }

            let activeStyleID = "ts\(cueIndex + 1)a\(segmentIndex + 1)"
            let inactiveStyleID = "ts\(cueIndex + 1)i\(segmentIndex + 1)"
            let runs = fcpxmlKaraokeTextRuns(
                text: cue.text,
                units: units,
                localTime: Double(localStart) / 1_000_000
            )
            let attributedText = runs.map { run in
                let styleID = run.isActive ? activeStyleID : inactiveStyleID
                return """
                <text-style ref="\(styleID)">\(xmlEscape(run.text))</text-style>
                """
            }
            .joined()
            let absoluteStart = startMicroseconds + localStart
            let segmentDuration = localEnd - localStart
            let partName = boundaries.count > 2
                ? " \(segmentIndex + 1)/\(boundaries.count - 1)"
                : ""

            // Keep title children to the common Final Cut/Resolve subset.
            // Resolve rejects FCPXML metadata elements nested inside titles.
            result += """
                <title name="\(xmlEscape(cue.text.prefix(32).description))\(partName)" lane="\(fcpxLane(cue))" offset="\(fcpxTime(microseconds: absoluteStart))" ref="r2" start="0s" duration="\(fcpxTime(microseconds: segmentDuration))">
                  <text>\(attributedText)</text>
                  <text-style-def id="\(activeStyleID)"><text-style font="Helvetica" fontSize="48" fontColor="\(fcpxColor(program.template.activeColorHex))" alignment="center"/></text-style-def>
                  <text-style-def id="\(inactiveStyleID)"><text-style font="Helvetica" fontSize="48" fontColor="\(fcpxColor(program.template.inactiveColorHex))" alignment="center"/></text-style-def>
                </title>

            """
        }
        return result
    }

    private static func fcpxmlKaraokeTextRuns(
        text: String,
        units: [KaraokeTimingUnit],
        localTime: Double
    ) -> [FCPXMLTextRun] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        var active = Array(repeating: false, count: characters.count)
        for unit in units where unit.startOffset <= localTime + 0.000_000_1 {
            let lower = min(max(0, unit.characterStart), characters.count)
            let upper = min(
                max(lower, unit.characterEnd),
                characters.count
            )
            guard lower < upper else { continue }
            for index in lower..<upper {
                active[index] = true
            }
        }

        var runs: [FCPXMLTextRun] = []
        var runStart = 0
        for index in 1...characters.count {
            if index == characters.count || active[index] != active[runStart] {
                runs.append(
                    FCPXMLTextRun(
                        text: String(characters[runStart..<index]),
                        isActive: active[runStart]
                    )
                )
                runStart = index
            }
        }
        return runs
    }

    private static func fcpxColor(_ hex: String) -> String {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard (raw.count == 6 || raw.count == 8),
              let value = UInt64(raw, radix: 16) else {
            return "1 1 1 1"
        }
        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64
        if raw.count == 8 {
            red = (value >> 24) & 0xff
            green = (value >> 16) & 0xff
            blue = (value >> 8) & 0xff
            alpha = value & 0xff
        } else {
            red = (value >> 16) & 0xff
            green = (value >> 8) & 0xff
            blue = value & 0xff
            alpha = 0xff
        }
        return [red, green, blue, alpha]
            .map { String(format: "%.6f", Double($0) / 255) }
            .joined(separator: " ")
    }

    private static func fcpxLane(_ cue: SubtitleItem) -> Int {
        max(1, cue.trackIndex + 1)
    }

    private static func tabularTime(_ seconds: Double) -> String {
        let milliseconds = Int((max(0, seconds) * 1_000).rounded())
        return String(
            format: "%02d:%02d:%02d.%03d",
            milliseconds / 3_600_000,
            (milliseconds / 60_000) % 60,
            (milliseconds / 1_000) % 60,
            milliseconds % 1_000
        )
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
        else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func xmlEscape<S: StringProtocol>(_ value: S) -> String {
        String(value)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func columnName(_ index: Int) -> String {
        var value = index
        var result = ""
        while value > 0 {
            value -= 1
            result.insert(Character(UnicodeScalar(65 + value % 26)!), at: result.startIndex)
            value /= 26
        }
        return result
    }

    private static func fcpxTime(_ seconds: Double) -> String {
        fcpxTime(microseconds: fcpxMicroseconds(seconds))
    }

    private static func fcpxMicroseconds(_ seconds: Double) -> Int {
        Int((max(0, seconds) * 1_000_000).rounded())
    }

    private static func fcpxTime(microseconds: Int) -> String {
        "\(max(0, microseconds))/1000000s"
    }

    private static func frameDuration(_ fps: Double) -> String {
        if abs(fps - 23.976) < 0.02 { return "1001/24000s" }
        if abs(fps - 29.97) < 0.02 { return "1001/30000s" }
        if abs(fps - 59.94) < 0.02 { return "1001/60000s" }
        let rounded = max(1, Int(fps.rounded()))
        return "1/\(rounded)s"
    }
}

private struct FCPXMLTextRun {
    var text: String
    var isActive: Bool
}

struct StoredZIPEntry {
    var path: String
    var data: Data
}

/// Minimal ZIP "store" writer used to create standards-compliant XLSX files
/// without adding a runtime dependency.
enum StoredZIPWriter {
    private struct CentralEntry {
        var pathData: Data
        var crc32: UInt32
        var size: UInt32
        var offset: UInt32
    }

    static func archive(_ entries: [StoredZIPEntry]) -> Data {
        var output = Data()
        var central: [CentralEntry] = []

        for entry in entries {
            let pathData = Data(entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            let offset = UInt32(output.count)
            output.appendLE(UInt32(0x04034B50))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0x0800))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(crc)
            output.appendLE(UInt32(entry.data.count))
            output.appendLE(UInt32(entry.data.count))
            output.appendLE(UInt16(pathData.count))
            output.appendLE(UInt16(0))
            output.append(pathData)
            output.append(entry.data)
            central.append(
                CentralEntry(
                    pathData: pathData,
                    crc32: crc,
                    size: UInt32(entry.data.count),
                    offset: offset
                )
            )
        }

        let centralOffset = UInt32(output.count)
        for entry in central {
            output.appendLE(UInt32(0x02014B50))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0x0800))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(entry.crc32)
            output.appendLE(entry.size)
            output.appendLE(entry.size)
            output.appendLE(UInt16(entry.pathData.count))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt32(0))
            output.appendLE(entry.offset)
            output.append(entry.pathData)
        }
        let centralSize = UInt32(output.count) - centralOffset
        output.appendLE(UInt32(0x06054B50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(central.count))
        output.appendLE(UInt16(central.count))
        output.appendLE(centralSize)
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))
        return output
    }
}

private enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB88320 & mask)
            }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
