//
//  ContentView.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/16.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var project = SubtitleProject()
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var navigationPath = NavigationPath()

    var body: some View {
        if sizeClass == .compact {
            // iPhone/手机端: 极简主界面导航流，主界面直接为 [播放器+时间轴]
            NavigationStack(path: $navigationPath) {
                MainContentView(project: project, isCompact: true, path: $navigationPath)
                    .navigationDestination(for: String.self) { value in
                        if value == "script" {
                            ScriptListView(project: project, isCompact: true, path: $navigationPath)
                        }
                    }
            }
            .onAppear {
                setupKeyboardMonitor()
            }
        } else {
            // iPad/Mac端: 经典左右分栏工作台
            NavigationSplitView {
                // MARK: - Right Sidebar: Script List
                ScriptListView(project: project, isCompact: false, path: .constant(NavigationPath()))
                    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
            } detail: {
                // MARK: - Main Content: Video + Timeline
                MainContentView(project: project, isCompact: false, path: .constant(NavigationPath()))
            }
            .onAppear {
                setupKeyboardMonitor()
            }
        }
    }

    // MARK: - Keyboard Monitor
    private func setupKeyboardMonitor() {
        #if os(macOS)
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // 💡 如果用户正在文字输入框/编辑界面中输入（isEditingText 为 true），直接透传，不做任何快捷键拦截！
            if project.isEditingText {
                return event
            }
            
            let isKeyDown = event.type == .keyDown
            let isKeyUp = event.type == .keyUp
            
            // J/K 键拍打打轴引擎（仅在 Creation 模式下且非编辑状态生效）
            if let chars = event.charactersIgnoringModifiers?.lowercased(), chars == "j" || chars == "k" {
                if project.editingMode == .creation {
                    if isKeyDown {
                        project.handleSlapKeyDown(key: chars)
                    } else if isKeyUp {
                        project.handleSlapKeyUp(key: chars)
                    }
                    return nil // 拦截并消费事件，避免系统提示音或其它干扰
                }
            }
            
            // 其它传统的键盘事件（仅在按下按键时触发）
            if isKeyDown {
                switch event.charactersIgnoringModifiers {
                case " ":
                    project.togglePlayback()
                    return nil
                case "\u{7F}", "\u{08}": // Backspace / Delete 按键
                    if !project.selectedIDs.isEmpty {
                        for id in project.selectedIDs {
                            project.deleteSubtitle(id: id)
                        }
                        project.selectedIDs.removeAll()
                        return nil
                    }
                    return event
                default:
                    return event
                }
            }
            
            return event
        }
        #endif
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let togglePlayback = Notification.Name("com.swiftsub.togglePlayback")
    static let requestCurrentTime = Notification.Name("com.swiftsub.requestCurrentTime")
    static let seekDelta = Notification.Name("com.swiftsub.seekDelta")
    static let changePlaybackSpeed = Notification.Name("com.swiftsub.changePlaybackSpeed")
}

#Preview {
    ContentView()
}
