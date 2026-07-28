//
//  StyleAndGroupStore.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/31.
//

import SwiftUI
import Combine

enum SubtitleGroupRole: String, CaseIterable, Identifiable, Codable, Equatable {
    case normal
    case secondaryLanguage
    case translatedDraft
    case effect
    case metadata

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "普通"
        case .secondaryLanguage: return "第二语言"
        case .translatedDraft: return "翻译副本"
        case .effect: return "特效"
        case .metadata: return "备注"
        }
    }
}

enum GroupExportPolicy: String, CaseIterable, Identifiable, Codable, Equatable {
    case includeInAllExports
    case textOnly
    case burnedInOnly
    case excludeByDefault
    case referenceOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .includeInAllExports: return "全部导出"
        case .textOnly: return "仅字幕文件"
        case .burnedInOnly: return "仅硬字幕"
        case .excludeByDefault: return "默认排除"
        case .referenceOnly: return "仅参考"
        }
    }
}

struct SubgroupStyle: Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var description: String
    var color: Color
    var fontName: String? = nil
    var fontSize: Double = 58
    var isBold: Bool = true
    var isItalic: Bool = false
    var isUnderline: Bool = false
    var isStrikethrough: Bool = false
    var outlineColor: Color = .black
    var outlineWidth: Double = 4
    var shadowColor: Color = .black
    var shadowRadius: Double = 5
    var backgroundColor: Color = .black
    var backgroundAlpha: Double = 0
    var isGlowing: Bool = false
    var alignment: SubtitleStyle.Alignment = .bottomCenter
    var marginLeftPercent: Double = 5
    var marginRightPercent: Double = 5
    var marginVerticalPercent: Double = 5
    var scaleX: Double = 1
    var scaleY: Double = 1
    var characterSpacing: Double = 0
    var rotationDegrees: Double = 0
}

struct SubGroupItem: Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var subName: String
    var role: SubtitleGroupRole = .normal
    var color: Color
    var isActive: Bool
    var style: String
    var isOverlayEnabled: Bool
    var isLocked: Bool = false
    var usesFadeInOut: Bool = false
    var exportPolicy: GroupExportPolicy = .includeInAllExports
    var sortOrder: Int = 0
}

struct StoredSubgroupStyle: Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var description: String
    var colorHex: String
    var fontName: String?
    var fontSize: Double
    var isBold: Bool
    var isItalic: Bool
    var isUnderline: Bool?
    var isStrikethrough: Bool?
    var outlineColorHex: String
    var outlineWidth: Double
    var shadowColorHex: String
    var shadowRadius: Double
    var backgroundColorHex: String
    var backgroundAlpha: Double
    var isGlowing: Bool
    var alignment: SubtitleStyle.Alignment?
    var marginLeftPercent: Double?
    var marginRightPercent: Double?
    var marginVerticalPercent: Double?
    var scaleX: Double?
    var scaleY: Double?
    var characterSpacing: Double?
    var rotationDegrees: Double?
}

struct StoredSubGroupItem: Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var subName: String
    var role: SubtitleGroupRole
    var colorHex: String
    var isActive: Bool
    var style: String
    var isOverlayEnabled: Bool
    var isLocked: Bool
    /// Optional so projects saved before fade controls were introduced continue to decode.
    var usesFadeInOut: Bool?
    var exportPolicy: GroupExportPolicy
    var sortOrder: Int
}

@MainActor
final class StyleAndGroupStore: ObservableObject {
    static let shared = StyleAndGroupStore()

    private var cancellables = Set<AnyCancellable>()
    var isRestoring = false

    init() {
        setupChangeTracking()
    }

    private func setupChangeTracking() {
        $styles
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self, !self.isRestoring else { return }
                NotificationCenter.default.post(name: .subtitleProjectDidChange, object: nil)
            }
            .store(in: &cancellables)

        $groups
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self, !self.isRestoring else { return }
                NotificationCenter.default.post(name: .subtitleProjectDidChange, object: nil)
            }
            .store(in: &cancellables)
    }

    enum DefaultStyleID {
        static let `default` = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        static let l2 = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        static let box = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        static let pingfang1080 = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
        static let pingfang4K = UUID(uuidString: "00000000-0000-4000-8000-000000000005")!
        static let oneFX = UUID(uuidString: "00000000-0000-4000-8000-000000000006")!
        static let barFX = UUID(uuidString: "00000000-0000-4000-8000-000000000007")!
    }

    enum DefaultGroupID {
        static let group1 = UUID(uuidString: "00000000-0000-4000-9000-000000000001")!
        static let group2 = UUID(uuidString: "00000000-0000-4000-9000-000000000002")!
        static let group3 = UUID(uuidString: "00000000-0000-4000-9000-000000000003")!
        static let group4 = UUID(uuidString: "00000000-0000-4000-9000-000000000004")!
        static let group5 = UUID(uuidString: "00000000-0000-4000-9000-000000000005")!
        static let groupA = UUID(uuidString: "00000000-0000-4000-9000-000000000006")!
        static let groupB = UUID(uuidString: "00000000-0000-4000-9000-000000000007")!
    }
    
    @Published var styles: [SubgroupStyle] = [
        SubgroupStyle(id: DefaultStyleID.default, name: "Default", description: "58 pt,平方-简", color: .white, fontSize: 58, isGlowing: false),
        SubgroupStyle(id: DefaultStyleID.l2, name: "Default-L2", description: "默认二级样式", color: .white, fontSize: 46, isGlowing: false),
        SubgroupStyle(id: DefaultStyleID.box, name: "Default-Box", description: "黑底白字样式", color: .white, fontSize: 58, outlineWidth: 0, backgroundAlpha: 0.68, isGlowing: false),
        SubgroupStyle(id: DefaultStyleID.pingfang1080, name: "Pingfang-1920x1080", description: "1080P 平方样式", color: .white, fontSize: 58, isGlowing: false),
        SubgroupStyle(id: DefaultStyleID.pingfang4K, name: "Pingfang-4K", description: "4K 平方样式", color: .white, fontSize: 96, outlineWidth: 7, shadowRadius: 9, isGlowing: false),
        SubgroupStyle(id: DefaultStyleID.oneFX, name: "OneFX", description: "动态特效一", color: Color(red: 0.0, green: 0.8, blue: 0.9), fontSize: 58, isGlowing: true),
        SubgroupStyle(id: DefaultStyleID.barFX, name: "BarFX", description: "动态特效二", color: Color(red: 0.5, green: 0.85, blue: 0.0), fontSize: 58, isGlowing: true)
    ]
    
    @Published var groups: [SubGroupItem] = [
        SubGroupItem(id: DefaultGroupID.group1, name: "组1", subName: "主字幕", role: .normal, color: Color(red: 1.0, green: 0.65, blue: 0.0), isActive: true, style: "Default", isOverlayEnabled: true, sortOrder: 0),
        SubGroupItem(id: DefaultGroupID.group2, name: "组2", subName: "普通字幕", role: .normal, color: Color(red: 0.5, green: 0.85, blue: 0.0), isActive: false, style: "Default", isOverlayEnabled: true, sortOrder: 1),
        SubGroupItem(id: DefaultGroupID.group3, name: "组3", subName: "普通字幕", role: .normal, color: Color(red: 0.0, green: 0.8, blue: 0.9), isActive: false, style: "Default", isOverlayEnabled: true, sortOrder: 2),
        SubGroupItem(id: DefaultGroupID.group4, name: "组4", subName: "普通字幕", role: .normal, color: Color(red: 0.0, green: 0.5, blue: 1.0), isActive: false, style: "Default", isOverlayEnabled: true, sortOrder: 3),
        SubGroupItem(id: DefaultGroupID.group5, name: "组5", subName: "普通字幕", role: .normal, color: Color(red: 0.6, green: 0.3, blue: 0.9), isActive: false, style: "Default", isOverlayEnabled: true, sortOrder: 4),
        SubGroupItem(id: DefaultGroupID.groupA, name: "专用组A (6)", subName: "第二语言", role: .secondaryLanguage, color: Color(red: 1.0, green: 0.1, blue: 0.6), isActive: false, style: "Default-L2", isOverlayEnabled: true, sortOrder: 5),
        SubGroupItem(id: DefaultGroupID.groupB, name: "专用组B (7)", subName: "翻译副本", role: .translatedDraft, color: Color(red: 1.0, green: 0.3, blue: 0.1), isActive: false, style: "Default-L2", isOverlayEnabled: true, exportPolicy: .excludeByDefault, sortOrder: 6)
    ]

    var sortedGroups: [SubGroupItem] {
        groups.sorted { lhs, rhs in
            if lhs.sortOrder == rhs.sortOrder { return lhs.name < rhs.name }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    var activeGroupID: UUID? {
        groups.first(where: { $0.isActive })?.id ?? groups.first?.id
    }

    var activeGroup: SubGroupItem? {
        activeGroupID.flatMap { group(id: $0) }
    }

    func group(id: UUID?) -> SubGroupItem? {
        guard let id else { return nil }
        return groups.first(where: { $0.id == id })
    }

    func style(id: UUID?) -> SubgroupStyle? {
        guard let id else { return nil }
        return styles.first(where: { $0.id == id })
    }

    func style(named name: String?) -> SubgroupStyle? {
        guard let name else { return nil }
        return styles.first(where: { $0.name == name })
    }

    func defaultStyle(for group: SubGroupItem?) -> SubgroupStyle? {
        style(named: group?.style) ?? styles.first
    }

    func setActiveGroup(_ id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        let updatedGroups = groups.map { group in
            var updated = group
            updated.isActive = group.id == id
            return updated
        }
        guard updatedGroups != groups else { return }
        // Publish one coherent snapshot. Mutating @Published array elements in a
        // loop emitted several intermediate states and could re-enter SwiftUI's
        // AsyncRenderer while a group switch was still in progress.
        groups = updatedGroups
    }

    /// Imports ASS styles as editable Strophe styles without replacing the
    /// user's built-in styles. The returned map is keyed by the original ASS
    /// style name so cues can bind to the imported visual style while retaining
    /// their exact source name in interchange metadata.
    @discardableResult
    func importASSStyles(
        _ records: [ASSStyleRecord],
        playResolutionX: Double?,
        playResolutionY: Double?
    ) -> [String: UUID] {
        var importedIDs: [String: UUID] = [:]

        for record in records {
            let sourceName = record.name
            let displayName = "ASS · \(sourceName)"
            let styleID = styles.first(where: { $0.name == displayName })?.id ?? UUID()
            let primary = assColor(record.value(named: "primarycolour")) ?? .white
            let outline = assColor(record.value(named: "outlinecolour")) ?? .black
            let shadow = assColor(record.value(named: "backcolour")) ?? .black
            let borderStyle = Int(record.value(named: "borderstyle") ?? "") ?? 1
            let marginL = Double(record.value(named: "marginl") ?? "") ?? 0
            let marginR = Double(record.value(named: "marginr") ?? "") ?? 0
            let marginV = Double(record.value(named: "marginv") ?? "") ?? 0

            let imported = SubgroupStyle(
                id: styleID,
                name: displayName,
                description: "ASS: \(sourceName)",
                color: primary.color,
                fontName: nonEmpty(record.value(named: "fontname")),
                fontSize: Double(record.value(named: "fontsize") ?? "") ?? 58,
                isBold: assBoolean(record.value(named: "bold")),
                isItalic: assBoolean(record.value(named: "italic")),
                isUnderline: assBoolean(record.value(named: "underline")),
                isStrikethrough: assBoolean(record.value(named: "strikeout")),
                outlineColor: outline.color,
                outlineWidth: Double(record.value(named: "outline") ?? "") ?? 0,
                shadowColor: shadow.color,
                shadowRadius: Double(record.value(named: "shadow") ?? "") ?? 0,
                backgroundColor: shadow.color,
                backgroundAlpha: borderStyle == 3 ? shadow.alpha : 0,
                isGlowing: false,
                alignment: assAlignment(record.value(named: "alignment")),
                marginLeftPercent: percent(marginL, of: playResolutionX),
                marginRightPercent: percent(marginR, of: playResolutionX),
                marginVerticalPercent: percent(marginV, of: playResolutionY),
                scaleX: (Double(record.value(named: "scalex") ?? "") ?? 100) / 100,
                scaleY: (Double(record.value(named: "scaley") ?? "") ?? 100) / 100,
                characterSpacing: Double(record.value(named: "spacing") ?? "") ?? 0,
                rotationDegrees: Double(record.value(named: "angle") ?? "") ?? 0
            )

            if let index = styles.firstIndex(where: { $0.id == styleID }) {
                styles[index] = imported
            } else {
                styles.append(imported)
            }
            importedIDs[sourceName] = styleID
        }
        return importedIDs
    }

    func shortcutGroup(number: Int) -> SubGroupItem? {
        let index = number - 1
        guard sortedGroups.indices.contains(index) else { return nil }
        return sortedGroups[index]
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func assBoolean(_ value: String?) -> Bool {
        guard let number = Int(value ?? "") else { return false }
        return number != 0
    }

    private func percent(_ value: Double, of dimension: Double?) -> Double {
        guard let dimension, dimension > 0 else { return 5 }
        return max(0, min(49, value / dimension * 100))
    }

    private func assAlignment(_ value: String?) -> SubtitleStyle.Alignment {
        switch Int(value ?? "") ?? 2 {
        case 1: return .bottomLeft
        case 2: return .bottomCenter
        case 3: return .bottomRight
        case 4: return .middleLeft
        case 5: return .middleCenter
        case 6: return .middleRight
        case 7: return .topLeft
        case 8: return .topCenter
        case 9: return .topRight
        default: return .bottomCenter
        }
    }

    private func assColor(_ value: String?) -> ResolvedRGBAColor? {
        guard var raw = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
              !raw.isEmpty else {
            return nil
        }
        raw = raw.replacingOccurrences(of: "&H", with: "")
        raw = raw.replacingOccurrences(of: "&", with: "")
        guard let encoded = UInt64(raw, radix: 16) else { return nil }

        let hasAlpha = raw.count > 6
        let alphaByte = hasAlpha ? Double((encoded >> 24) & 0xFF) : 0
        return ResolvedRGBAColor(
            red: Double(encoded & 0xFF) / 255,
            green: Double((encoded >> 8) & 0xFF) / 255,
            blue: Double((encoded >> 16) & 0xFF) / 255,
            alpha: 1 - alphaByte / 255
        )
    }

    func storedStyles() -> [StoredSubgroupStyle] {
        styles.map { style in
            StoredSubgroupStyle(
                id: style.id,
                name: style.name,
                description: style.description,
                colorHex: style.color.resolvedRGBA.hexString,
                fontName: style.fontName,
                fontSize: style.fontSize,
                isBold: style.isBold,
                isItalic: style.isItalic,
                isUnderline: style.isUnderline,
                isStrikethrough: style.isStrikethrough,
                outlineColorHex: style.outlineColor.resolvedRGBA.hexString,
                outlineWidth: style.outlineWidth,
                shadowColorHex: style.shadowColor.resolvedRGBA.hexString,
                shadowRadius: style.shadowRadius,
                backgroundColorHex: style.backgroundColor.resolvedRGBA.hexString,
                backgroundAlpha: style.backgroundAlpha,
                isGlowing: style.isGlowing,
                alignment: style.alignment,
                marginLeftPercent: style.marginLeftPercent,
                marginRightPercent: style.marginRightPercent,
                marginVerticalPercent: style.marginVerticalPercent,
                scaleX: style.scaleX,
                scaleY: style.scaleY,
                characterSpacing: style.characterSpacing,
                rotationDegrees: style.rotationDegrees
            )
        }
    }

    func storedGroups() -> [StoredSubGroupItem] {
        groups.map { group in
            StoredSubGroupItem(
                id: group.id,
                name: group.name,
                subName: group.subName,
                role: group.role,
                colorHex: group.color.resolvedRGBA.hexString,
                isActive: group.isActive,
                style: group.style,
                isOverlayEnabled: group.isOverlayEnabled,
                isLocked: group.isLocked,
                usesFadeInOut: group.usesFadeInOut,
                exportPolicy: group.exportPolicy,
                sortOrder: group.sortOrder
            )
        }
    }

    func restore(styles storedStyles: [StoredSubgroupStyle]?, groups storedGroups: [StoredSubGroupItem]?) {
        isRestoring = true
        defer { isRestoring = false }
        if let storedStyles, !storedStyles.isEmpty {
            styles = storedStyles.map { stored in
                SubgroupStyle(
                    id: stored.id,
                    name: stored.name,
                    description: stored.description,
                    color: ResolvedRGBAColor(hex: stored.colorHex)?.color ?? .white,
                    fontName: stored.fontName,
                    fontSize: stored.fontSize,
                    isBold: stored.isBold,
                    isItalic: stored.isItalic,
                    isUnderline: stored.isUnderline ?? false,
                    isStrikethrough: stored.isStrikethrough ?? false,
                    outlineColor: ResolvedRGBAColor(hex: stored.outlineColorHex)?.color ?? .black,
                    outlineWidth: stored.outlineWidth,
                    shadowColor: ResolvedRGBAColor(hex: stored.shadowColorHex)?.color ?? .black,
                    shadowRadius: stored.shadowRadius,
                    backgroundColor: ResolvedRGBAColor(hex: stored.backgroundColorHex)?.color ?? .black,
                    backgroundAlpha: stored.backgroundAlpha,
                    isGlowing: stored.isGlowing,
                    alignment: stored.alignment ?? .bottomCenter,
                    marginLeftPercent: stored.marginLeftPercent ?? 5,
                    marginRightPercent: stored.marginRightPercent ?? 5,
                    marginVerticalPercent: stored.marginVerticalPercent ?? 5,
                    scaleX: stored.scaleX ?? 1,
                    scaleY: stored.scaleY ?? 1,
                    characterSpacing: stored.characterSpacing ?? 0,
                    rotationDegrees: stored.rotationDegrees ?? 0
                )
            }
        }

        if let storedGroups, !storedGroups.isEmpty {
            groups = storedGroups.map { stored in
                SubGroupItem(
                    id: stored.id,
                    name: stored.name,
                    subName: stored.subName,
                    role: stored.role,
                    color: ResolvedRGBAColor(hex: stored.colorHex)?.color ?? .orange,
                    isActive: stored.isActive,
                    style: stored.style,
                    isOverlayEnabled: stored.isOverlayEnabled,
                    isLocked: stored.isLocked,
                    usesFadeInOut: stored.usesFadeInOut ?? false,
                    exportPolicy: stored.exportPolicy,
                    sortOrder: stored.sortOrder
                )
            }
            if !groups.contains(where: { $0.isActive }), !groups.isEmpty {
                groups[0].isActive = true
            }
        }
    }
}

extension ResolvedRGBAColor {
    var hexString: String {
        let r = Int((max(0, min(1, red)) * 255).rounded())
        let g = Int((max(0, min(1, green)) * 255).rounded())
        let b = Int((max(0, min(1, blue)) * 255).rounded())
        let a = Int((max(0, min(1, alpha)) * 255).rounded())
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
