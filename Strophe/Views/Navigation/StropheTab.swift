//
//  StropheTab.swift
//  Strophe
//

import Foundation

/// Destinations shared by the compact tab bar and the wide sidebar.
enum StropheTab: Int, CaseIterable, Hashable {
    case scriptList = 0
    case styleManager = 1
    case subGroup = 2
    case editor = 3
    case settings = 4

    var title: String {
        switch self {
        case .scriptList: return String(localized: "script")
        case .styleManager: return String(localized: "style")
        case .subGroup: return String(localized: "group")
        case .editor: return String(localized: "timeline")
        case .settings: return String(localized: "settings")
        }
    }

    var systemImage: String {
        switch self {
        case .scriptList: return "doc.text"
        case .styleManager: return "textformat.alt"
        case .subGroup: return "square.stack.3d.up"
        case .editor: return "timeline.selection"
        case .settings: return "gear"
        }
    }

    static let wideTabs: [StropheTab] = [.editor, .styleManager, .subGroup, .settings]

    static let compactTabs: [StropheTab] = [.scriptList, .editor, .styleManager, .subGroup, .settings]
}
