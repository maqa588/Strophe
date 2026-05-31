//
//  StyleAndGroupStore.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/31.
//

import SwiftUI
import Combine

struct SubgroupStyle: Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var description: String
    var color: Color
    var isGlowing: Bool = false
}

struct SubGroupItem: Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var subName: String
    var color: Color
    var isActive: Bool
    var style: String
    var isOverlayEnabled: Bool
    var isFlagged: Bool
}

class StyleAndGroupStore: ObservableObject {
    static let shared = StyleAndGroupStore()
    
    @Published var styles: [SubgroupStyle] = [
        SubgroupStyle(name: "Default", description: "58 pt,平方-简", color: .white, isGlowing: false),
        SubgroupStyle(name: "Default-L2", description: "默认二级样式", color: .white, isGlowing: false),
        SubgroupStyle(name: "Default-Box", description: "黑底白字样式", color: .white, isGlowing: false),
        SubgroupStyle(name: "Pingfang-1920x1080", description: "1080P 平方样式", color: .white, isGlowing: false),
        SubgroupStyle(name: "Pingfang-4K", description: "4K 平方样式", color: .white, isGlowing: false),
        SubgroupStyle(name: "OneFX", description: "动态特效一", color: Color(red: 0.0, green: 0.8, blue: 0.9), isGlowing: true),
        SubgroupStyle(name: "BarFX", description: "动态特效二", color: Color(red: 0.5, green: 0.85, blue: 0.0), isGlowing: true)
    ]
    
    @Published var groups: [SubGroupItem] = [
        SubGroupItem(name: "组1", subName: "默认分组", color: Color(red: 1.0, green: 0.65, blue: 0.0), isActive: true, style: "Default", isOverlayEnabled: true, isFlagged: false),
        SubGroupItem(name: "组2", subName: "默认分组", color: Color(red: 0.5, green: 0.85, blue: 0.0), isActive: false, style: "Default", isOverlayEnabled: true, isFlagged: false),
        SubGroupItem(name: "组3", subName: "默认分组", color: Color(red: 0.0, green: 0.8, blue: 0.9), isActive: false, style: "Default", isOverlayEnabled: true, isFlagged: false),
        SubGroupItem(name: "组4", subName: "默认分组", color: Color(red: 0.0, green: 0.5, blue: 1.0), isActive: false, style: "Default", isOverlayEnabled: true, isFlagged: false),
        SubGroupItem(name: "组5", subName: "默认分组", color: Color(red: 0.6, green: 0.3, blue: 0.9), isActive: false, style: "Default", isOverlayEnabled: true, isFlagged: false),
        SubGroupItem(name: "专用组A (6)", subName: "默认分组", color: Color(red: 1.0, green: 0.1, blue: 0.6), isActive: false, style: "Default-L2", isOverlayEnabled: true, isFlagged: true),
        SubGroupItem(name: "专用组B (7)", subName: "默认分组", color: Color(red: 1.0, green: 0.3, blue: 0.1), isActive: false, style: "Default-L2", isOverlayEnabled: true, isFlagged: false)
    ]
}
