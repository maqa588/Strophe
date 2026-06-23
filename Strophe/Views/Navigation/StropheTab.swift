//
//  StropheTab.swift
//  Strophe
//

import Foundation

/// 앱 전체 탭 종류를 정의합니다.
/// - iPhone (compact): 문고 / 편집기 / 설정 세 탭 모두 표시
/// - iPad / macOS (regular): 편집기 / 설정 두 탭만 하단 nav bar에 표시
///   (문고는 편집기 탭의 왼쪽 컬럼에 내장)
enum StropheTab: Int, CaseIterable, Hashable {
    case scriptList = 0   // "文稿"  — iPhone 전용 탭
    case styleManager = 1  // "样式"  - New style manager tab
    case subGroup   = 2   // "组别"  - New subgroup tab
    case editor     = 3   // "编辑器"
    case settings   = 4   // "设置"

    var title: String {
        switch self {
        case .scriptList:   return String(localized: "文稿")
        case .styleManager: return String(localized: "样式")
        case .subGroup:     return String(localized: "组别")
        case .editor:       return String(localized: "编辑器")
        case .settings:     return String(localized: "设置")
        }
    }

    var systemImage: String {
        switch self {
        case .scriptList:   return "doc.text"
        case .styleManager: return "textformat.alt"
        case .subGroup:     return "square.stack.3d.up"
        case .editor:       return "waveform.and.mic"
        case .settings:     return "gear"
        }
    }

    /// iPad / macOS 하단 nav bar에 표시할 탭 목록
    static let wideTabs: [StropheTab]    = [.editor, .styleManager, .subGroup, .settings]

    /// iPhone 하단 nav bar에 표시할 탭 목록
    static let compactTabs: [StropheTab] = [.scriptList, .editor, .styleManager, .subGroup, .settings]
}
