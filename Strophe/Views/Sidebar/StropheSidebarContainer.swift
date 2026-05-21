//
//  StropheSidebarContainer.swift
//  Strophe
//

import SwiftUI

struct StropheSidebarContainer: View, Equatable {
    @ObservedObject var project: SubtitleProject
    @Binding var selectedTab: StropheTab
    
    static func == (lhs: StropheSidebarContainer, rhs: StropheSidebarContainer) -> Bool {
        lhs.project === rhs.project &&
        lhs.selectedTab == rhs.selectedTab
    }
    
    var body: some View {
        #if os(macOS)
        // 💻 macOS 平台：采用“边到边”的扁平化原生侧边栏设计，彻底消灭三层套娃边框与留白失衡
        sidebarContent
            // 💡 使用标准的 AppKit 侧边栏模糊底色，填满整个区域
            .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
            .hideSidebarSystemNavigationBar()
        #else
        // 📱 iPadOS/iOS 平台：保留你非常满意的精致悬浮玻璃卡片布局
        if #available(iOS 26.0, macOS 26.0, *) {
            sidebarContent
                .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
                .padding(.leading, 12)
                .padding(.bottom, 12)
                .padding(.trailing, 4)
                .hideSidebarSystemNavigationBar()
        } else {
            sidebarContent
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.leading, 12)
                .padding(.bottom, 12)
                .padding(.trailing, 4)
                .hideSidebarSystemNavigationBar()
        }
        #endif
    }
    
    @ViewBuilder
    private var sidebarContent: some View {
        VStack(spacing: 0) {
            
            // 💡 核心修复 1：使用 ZStack 进行大卡片标题的“绝对水平居中”
            ZStack {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                    Text(selectedTab.title)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.stropheText)
            }
            .frame(height: 52) // 52pt 完美对齐右侧
            
            // 2. 侧边栏列表内容
            Group {
                switch selectedTab {
                case .editor, .scriptList:
                    ScriptListView(project: project)
                case .settings:
                    SettingsPlaceholderView()
                }
            }
            .frame(maxHeight: .infinity)
            
            // 3. 柔和分割线
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.stropheBorder)
            
            // 4. 自绘 Tab 导航栏区域
            StropheTabBar(selectedTab: $selectedTab, tabs: StropheTab.wideTabs)
                .padding(.top, 12)
        }
        // 💡 核心修复 2：将加号按钮塞回系统原生 Toolbar
        // macOS 系统会自动把它和 [折叠侧栏] 按钮并排进行避让渲染，绝不冲突
        .toolbar {
            if selectedTab == .editor || selectedTab == .scriptList {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("粘贴文稿") {
                            NotificationCenter.default.post(name: .strophePasteScript, object: nil)
                        }
                        Button("导入字幕文件") {
                            NotificationCenter.default.post(name: .stropheImportScriptFile, object: nil)
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .help(String(localized: "粘贴或导入文稿"))
                }
            }
        }
    }
}

// MARK: - 跨平台隐藏导航栏助手

extension View {
    @ViewBuilder
    fileprivate func hideSidebarSystemNavigationBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self.navigationTitle("")
        #endif
    }
}