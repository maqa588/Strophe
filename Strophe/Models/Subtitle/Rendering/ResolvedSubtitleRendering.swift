import Foundation
import SwiftUI

nonisolated struct ResolvedRGBAColor: Sendable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let white = ResolvedRGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let black = ResolvedRGBAColor(red: 0, green: 0, blue: 0, alpha: 1)

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    func withAlpha(_ newAlpha: Double) -> ResolvedRGBAColor {
        ResolvedRGBAColor(red: red, green: green, blue: blue, alpha: newAlpha)
    }
}

nonisolated enum SubtitlePlacementMetrics {
    /// EBU R 95 / ITU-R BT.1848 safe areas for 16:9 television production.
    static let actionSafeInsetRatio = 0.035
    static let graphicsSafeInsetRatio = 0.05

    static func placementRect(for canvasSize: CGSize, style: ResolvedSubtitleStyle) -> CGRect {
        let left = canvasSize.width * clampedPercent(style.marginLeftPercent)
        let right = canvasSize.width * clampedPercent(style.marginRightPercent)
        let vertical = canvasSize.height * clampedPercent(style.marginVerticalPercent)

        return CGRect(
            x: left,
            y: vertical,
            width: max(0, canvasSize.width - left - right),
            height: max(0, canvasSize.height - vertical * 2)
        )
    }

    private static func clampedPercent(_ value: Double) -> CGFloat {
        CGFloat(max(0, min(49, value)) / 100)
    }
}

extension SubtitleStyle.Alignment {
    var swiftUIAlignment: SwiftUI.Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topCenter: return .top
        case .topRight: return .topTrailing
        case .middleLeft: return .leading
        case .middleCenter: return .center
        case .middleRight: return .trailing
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }

    var swiftUITextAlignment: TextAlignment {
        switch self {
        case .topLeft, .middleLeft, .bottomLeft: return .leading
        case .topCenter, .middleCenter, .bottomCenter: return .center
        case .topRight, .middleRight, .bottomRight: return .trailing
        }
    }

}

nonisolated struct ResolvedSubtitleStyle: Sendable, Equatable, Hashable {
    var name: String
    var fontName: String?
    var fontSize: Double
    var textColor: ResolvedRGBAColor
    var outlineColor: ResolvedRGBAColor
    var outlineWidth: Double
    var shadowColor: ResolvedRGBAColor
    var shadowRadius: Double
    var backgroundColor: ResolvedRGBAColor?
    var isBold: Bool
    var isItalic: Bool
    var isUnderline: Bool
    var isStrikethrough: Bool
    var isGlowing: Bool
    var alignment: SubtitleStyle.Alignment
    var marginLeftPercent: Double
    var marginRightPercent: Double
    var marginVerticalPercent: Double
    var scaleX: Double
    var scaleY: Double
    var characterSpacing: Double
    var rotationDegrees: Double

    static let fallback = ResolvedSubtitleStyle(
        name: "Default",
        fontName: nil,
        fontSize: 58,
        textColor: .white,
        outlineColor: .black,
        outlineWidth: 4,
        shadowColor: .black.withAlpha(0.75),
        shadowRadius: 5,
        backgroundColor: nil,
        isBold: false,
        isItalic: false,
        isUnderline: false,
        isStrikethrough: false,
        isGlowing: false,
        alignment: .bottomCenter,
        marginLeftPercent: 5,
        marginRightPercent: 5,
        marginVerticalPercent: 5,
        scaleX: 1,
        scaleY: 1,
        characterSpacing: 0,
        rotationDegrees: 0
    )
}

nonisolated struct ResolvedSubtitleCue: Identifiable, Sendable, Equatable, Hashable {
    var id: UUID
    var text: String
    var startTime: Double
    var endTime: Double
    var style: ResolvedSubtitleStyle
    var groupID: UUID?
    var trackIndex: Int
}

struct HardSubtitleBitmapView: View {
    let text: String
    let style: ResolvedSubtitleStyle
    let canvasSize: CGSize
    let displayScale: CGFloat

    var body: some View {
        if let image = SubtitleBitmapRenderer.makeImage(
            text: text,
            style: style,
            canvasSize: canvasSize
        ) {
            Image(
                decorative: image,
                scale: max(0.0001, 1 / displayScale),
                orientation: .up
            )
            .interpolation(.high)
            .fixedSize()
        }
    }
}

extension Color {
    nonisolated var resolvedRGBA: ResolvedRGBAColor {
        #if canImport(AppKit)
        let platformColor = NSColor(self)
        let converted = platformColor.usingColorSpace(.deviceRGB) ?? platformColor
        return ResolvedRGBAColor(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            alpha: Double(converted.alphaComponent)
        )
        #elseif canImport(UIKit)
        let platformColor = UIColor(self)
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1
        platformColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return ResolvedRGBAColor(
            red: Double(red),
            green: Double(green),
            blue: Double(blue),
            alpha: Double(alpha)
        )
        #else
        return .white
        #endif
    }
}

extension ResolvedRGBAColor {
    init?(hex: String?) {
        guard let hex else { return nil }
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") {
            raw.removeFirst()
        }

        guard raw.count == 6 || raw.count == 8,
              let value = UInt64(raw, radix: 16) else {
            return nil
        }

        if raw.count == 8 {
            red = Double((value >> 24) & 0xff) / 255.0
            green = Double((value >> 16) & 0xff) / 255.0
            blue = Double((value >> 8) & 0xff) / 255.0
            alpha = Double(value & 0xff) / 255.0
        } else {
            red = Double((value >> 16) & 0xff) / 255.0
            green = Double((value >> 8) & 0xff) / 255.0
            blue = Double(value & 0xff) / 255.0
            alpha = 1
        }
    }
}

@MainActor
extension SubtitleProject {
    func resolvedSubtitleCues(store: StyleAndGroupStore = .shared) -> [ResolvedSubtitleCue] {
        items.compactMap { item in
            guard let start = item.startTime,
                  let end = item.endTime,
                  end >= start,
                  !item.isHidden,
                  !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            let group = resolvedGroup(for: item, store: store)
            if let group, !group.isOverlayEnabled || group.exportPolicy == .referenceOnly || group.exportPolicy == .textOnly {
                return nil
            }

            return ResolvedSubtitleCue(
                id: item.id,
                text: item.text,
                startTime: start,
                endTime: end,
                style: resolvedStyle(for: item, group: group, store: store),
                groupID: group?.id,
                trackIndex: item.trackIndex
            )
        }
    }

    func resolvedSubtitleCue(at time: Double, store: StyleAndGroupStore = .shared) -> ResolvedSubtitleCue? {
        if let activeID = activeSlapSubtitleID,
           let item = items.first(where: { $0.id == activeID }),
           let cue = resolvedCue(for: item, store: store) {
            return cue
        }

        guard time.isFinite else { return nil }
        return items.lazy.compactMap { item -> ResolvedSubtitleCue? in
            guard let start = item.startTime,
                  let end = item.endTime,
                  !item.isHidden,
                  time >= start,
                  time <= end else {
                return nil
            }
            return self.resolvedCue(for: item, store: store)
        }
        .sorted { lhs, rhs in
            if lhs.groupID == store.activeGroupID && rhs.groupID != store.activeGroupID { return true }
            if lhs.groupID != store.activeGroupID && rhs.groupID == store.activeGroupID { return false }
            return lhs.trackIndex < rhs.trackIndex
        }
        .first
    }

    func resolvedSubtitleCues(at time: Double, store: StyleAndGroupStore = .shared) -> [ResolvedSubtitleCue] {
        guard time.isFinite else { return [] }
        return items.compactMap { item -> ResolvedSubtitleCue? in
            guard let start = item.startTime,
                  let end = item.endTime,
                  time >= start,
                  time <= end else {
                return nil
            }
            return self.resolvedCue(for: item, store: store)
        }
        .sorted {
            if $0.groupID == store.activeGroupID && $1.groupID != store.activeGroupID { return false }
            if $0.groupID != store.activeGroupID && $1.groupID == store.activeGroupID { return true }
            if $0.trackIndex == $1.trackIndex { return $0.startTime < $1.startTime }
            return $0.trackIndex < $1.trackIndex
        }
    }

    private func resolvedCue(for item: SubtitleItem, store: StyleAndGroupStore) -> ResolvedSubtitleCue? {
        guard let start = item.startTime,
              let end = item.endTime,
              end >= start,
              !item.isHidden,
              !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let group = resolvedGroup(for: item, store: store)
        if let group, !group.isOverlayEnabled || group.exportPolicy == .referenceOnly || group.exportPolicy == .textOnly {
            return nil
        }

        return ResolvedSubtitleCue(
            id: item.id,
            text: item.text,
            startTime: start,
            endTime: end,
            style: resolvedStyle(for: item, group: group, store: store),
            groupID: group?.id,
            trackIndex: item.trackIndex
        )
    }

    private func resolvedGroup(for item: SubtitleItem, store: StyleAndGroupStore) -> SubGroupItem? {
        if let group = store.group(id: item.groupID) {
            return group
        }

        return store.activeGroup ?? store.groups.first
    }

    private func resolvedStyle(
        for item: SubtitleItem,
        group: SubGroupItem?,
        store: StyleAndGroupStore
    ) -> ResolvedSubtitleStyle {
        let styleName = group?.style
        let subgroupStyle = item.styleID.flatMap { id in
            store.styles.first(where: { $0.id == id })
        } ?? styleName.flatMap { name in
            store.styles.first(where: { $0.name == name })
        } ?? store.styles.first

        var resolved = ResolvedSubtitleStyle.fallback
        resolved.name = subgroupStyle?.name ?? styleName ?? resolved.name
        resolved.fontName = subgroupStyle?.fontName
        resolved.textColor = ResolvedRGBAColor(hex: item.styleOverrides?.textColorHex)
            ?? subgroupStyle?.color.resolvedRGBA
            ?? resolved.textColor
        resolved.fontSize = item.styleOverrides?.fontSize ?? subgroupStyle?.fontSize ?? inferredFontSize(from: subgroupStyle) ?? resolved.fontSize
        resolved.isBold = item.styleOverrides?.isBold ?? subgroupStyle?.isBold ?? resolved.isBold
        resolved.isItalic = item.styleOverrides?.isItalic ?? subgroupStyle?.isItalic ?? resolved.isItalic
        resolved.isUnderline = subgroupStyle?.isUnderline ?? resolved.isUnderline
        resolved.isStrikethrough = subgroupStyle?.isStrikethrough ?? resolved.isStrikethrough
        resolved.outlineColor = subgroupStyle?.outlineColor.resolvedRGBA ?? resolved.outlineColor
        resolved.outlineWidth = subgroupStyle?.outlineWidth ?? resolved.outlineWidth
        resolved.shadowColor = subgroupStyle?.shadowColor.resolvedRGBA ?? resolved.shadowColor
        resolved.shadowRadius = subgroupStyle?.shadowRadius ?? resolved.shadowRadius
        resolved.isGlowing = subgroupStyle?.isGlowing ?? resolved.isGlowing
        resolved.alignment = subgroupStyle?.alignment ?? resolved.alignment
        resolved.marginLeftPercent = subgroupStyle?.marginLeftPercent ?? resolved.marginLeftPercent
        resolved.marginRightPercent = subgroupStyle?.marginRightPercent ?? resolved.marginRightPercent
        resolved.marginVerticalPercent = subgroupStyle?.marginVerticalPercent ?? resolved.marginVerticalPercent
        resolved.scaleX = subgroupStyle?.scaleX ?? resolved.scaleX
        resolved.scaleY = subgroupStyle?.scaleY ?? resolved.scaleY
        resolved.characterSpacing = subgroupStyle?.characterSpacing ?? resolved.characterSpacing
        resolved.rotationDegrees = subgroupStyle?.rotationDegrees ?? resolved.rotationDegrees
        if let subgroupStyle, subgroupStyle.backgroundAlpha > 0 {
            resolved.backgroundColor = subgroupStyle.backgroundColor.resolvedRGBA.withAlpha(subgroupStyle.backgroundAlpha)
        }

        if resolved.name.localizedCaseInsensitiveContains("box") {
            resolved.backgroundColor = .black.withAlpha(0.68)
            resolved.outlineWidth = 0
        }

        if resolved.isGlowing {
            resolved.shadowColor = resolved.textColor.withAlpha(0.85)
            resolved.shadowRadius = 12
        }

        return resolved
    }

    private func inferredFontSize(from style: SubgroupStyle?) -> Double? {
        guard let style else { return nil }
        let source = "\(style.name) \(style.description)"
        if source.localizedCaseInsensitiveContains("4k") {
            return 96
        }
        if source.localizedCaseInsensitiveContains("1080") {
            return 58
        }

        let digits = source.split { !$0.isNumber }.compactMap { Double($0) }
        return digits.first { $0 >= 10 && $0 <= 240 }
    }
}
