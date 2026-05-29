//
//  StropheSidebarContainer.swift
//  Strophe
//

import SwiftUI

struct StropheSidebarContainer: View {
    @ObservedObject var project: SubtitleProject
    @Binding var selectedTab: StropheTab
    @Binding var settingsPath: [SettingsRoute]

    private var usesLiquidGlassNavigation: Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) { return true }
        #elseif os(macOS)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, 12)
                .padding(.bottom, 12)
                .padding(.trailing, 4)
                .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
                .hideSidebarSystemNavigationBar()
        } else {
            sidebarContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, 12)
                .padding(.bottom, 12)
                .padding(.trailing, 4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .hideSidebarSystemNavigationBar()
        }
        #endif
    }
    
    @ViewBuilder
    private var sidebarContent: some View {
        Group {
            if usesLiquidGlassNavigation {
                ZStack(alignment: .bottom) {
                    sidebarPrimaryContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    StropheTabBar(selectedTab: $selectedTab, tabs: StropheTab.wideTabs)
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
            } else {
                VStack(spacing: 0) {
                    sidebarPrimaryContent
                        .frame(maxHeight: .infinity)

                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color.stropheBorder)

                    StropheTabBar(selectedTab: $selectedTab, tabs: StropheTab.wideTabs)
                        .padding(.top, 12)
                }
            }
        }
        // System toolbar: on macOS this is auto-paired with the sidebar toggle button.
        // On iPadOS, the navbar is now visible (we only hide its background via
        // .toolbarBackground(.hidden)), so .toolbar items render correctly here too.
        .toolbar {
            if selectedTab == .editor || selectedTab == .scriptList {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            NotificationCenter.default.post(name: .strophePasteScript, object: nil)
                        } label: {
                            Label("粘贴文稿", systemImage: "doc.on.clipboard")
                        }
                        Button {
                            NotificationCenter.default.post(name: .stropheImportScriptFile, object: nil)
                        } label: {
                            Label("导入字幕文件", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            NotificationCenter.default.post(name: .stropheStartSpeechRecognition, object: nil)
                        } label: {
                            Label("语音识别", systemImage: "waveform.and.mic")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                    }
                    #if os(macOS)
                    .help(String(localized: "粘贴或导入文稿"))
                    #endif
                }
            }
        }
    }

    @ViewBuilder
    private var sidebarPrimaryContent: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 6) {
                    Image(systemName: selectedTab.systemImage)
                        .font(.system(size: 13, weight: .medium))
                    Text(selectedTab.title)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.stropheText)
            }
            .frame(height: 52)

            Group {
                switch selectedTab {
                case .editor, .scriptList:
                    ScriptListView(project: project)
                case .settings:
                    SettingsPlaceholderView(settingsPath: $settingsPath)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Cross-platform navigation bar helper

extension View {
    @ViewBuilder
    fileprivate func hideSidebarSystemNavigationBar() -> some View {
        #if os(iOS)
        // Clear system navigation title (our custom ZStack header is the only title).
        // Keep .toolbarBackground(.hidden) so the bar's layout footprint remains
        // stable and .toolbar items (plus button, sidebar toggle) render correctly.
        self
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        #else
        self.navigationTitle("")
        #endif
    }
}
