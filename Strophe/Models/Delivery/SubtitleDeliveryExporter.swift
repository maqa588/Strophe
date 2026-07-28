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

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .excel: return "xlsx"
        case .fcpxml: return "fcpxml"
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
        }
    }
}

extension UTType {
    static nonisolated let stropheExcelWorkbook =
        UTType(importedAs: "org.openxmlformats.spreadsheetml.sheet")
    static nonisolated let stropheFCPXML =
        UTType(importedAs: "com.apple.final-cut-pro.xml")
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
            .stropheExcelWorkbook,
            .stropheFCPXML
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
    ) -> Data {
        switch format {
        case .csv:
            return csv(project: project)
        case .excel:
            return excel(project: project)
        case .fcpxml:
            return fcpxml(project: project)
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
        let cues = project.items
            .filter { $0.startTime != nil && $0.endTime != nil && !$0.isHidden }
            .sorted(by: project.stableSubtitleSort)
        let duration = max(cues.compactMap(\.endTime).max() ?? 1, 1)
        var titles = ""
        for (index, cue) in cues.enumerated() {
            guard let start = cue.startTime, let end = cue.endTime else { continue }
            let cueDuration = max(0.001, end - start)
            let styleID = "ts\(index + 1)"
            titles += """
                <title name="\(xmlEscape(cue.text.prefix(40).description))" lane="1" offset="\(fcpxTime(start))" ref="r2" start="0s" duration="\(fcpxTime(cueDuration))">
                  <text><text-style ref="\(styleID)">\(xmlEscape(cue.text))</text-style></text>
                  <text-style-def id="\(styleID)"><text-style font="Helvetica" fontSize="48" fontColor="1 1 1 1" alignment="center"/></text-style-def>
                </title>

            """
        }
        let projectName = project.documentDisplayName.isEmpty
            ? "Strophe Subtitles"
            : project.documentDisplayName
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
          <resources>
            <format id="r1" name="FFVideoFormat1080p\(Int(project.videoFrameRate.rounded()))" frameDuration="\(frameDuration(project.videoFrameRate))" width="1920" height="1080" colorSpace="1-1-1 (Rec. 709)"/>
            <effect id="r2" name="Basic Title" uid=".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"/>
          </resources>
          <library>
            <event name="Strophe">
              <project name="\(xmlEscape(projectName))">
                <sequence format="r1" duration="\(fcpxTime(duration))" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
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
        "\(Int((max(0, seconds) * 1_000_000).rounded()))/1000000s"
    }

    private static func frameDuration(_ fps: Double) -> String {
        if abs(fps - 23.976) < 0.02 { return "1001/24000s" }
        if abs(fps - 29.97) < 0.02 { return "1001/30000s" }
        if abs(fps - 59.94) < 0.02 { return "1001/60000s" }
        let rounded = max(1, Int(fps.rounded()))
        return "1/\(rounded)s"
    }
}

private struct StoredZIPEntry {
    var path: String
    var data: Data
}

/// Minimal ZIP "store" writer used to create standards-compliant XLSX files
/// without adding a runtime dependency.
private enum StoredZIPWriter {
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
