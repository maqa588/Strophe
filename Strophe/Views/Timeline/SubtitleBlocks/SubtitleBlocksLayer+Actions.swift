//
//  Subtitle editing sheets, menus, and contextual actions.
//

import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import GameController
#endif

extension SubtitleBlocksLayer {
    // MARK: Editing and context menu

    #if os(iOS)
    @ViewBuilder
    var mobileBlockActionsSheet: some View {
        if let item = contextItem {
            let locked = isLocked(item)
            NavigationStack {
                List {
                    Section {
                        Button {
                            project.selectedIDs.insert(item.id)
                            project.isSubtitleMultiSelecting = true
                            isShowingMobileBlockActions = false
                        } label: {
                            mobileActionLabel("多选字幕块", systemImage: "checklist")
                        }
                        .buttonStyle(.plain)
                        Button {
                            guard let groupID = renderModel.group(for: item)?.id else { return }
                            project.selectedIDs = Set(renderModel.items.filter {
                                renderModel.group(for: $0)?.id == groupID
                            }.map(\.id))
                            project.isSubtitleMultiSelecting = project.selectedIDs.count > 1
                            isShowingMobileBlockActions = false
                        } label: {
                            mobileActionLabel("选择同组全部", systemImage: "checkmark.square.stack")
                        }
                        .buttonStyle(.plain)
                        Button {
                            performAfterDismissingMobileMenu { beginEditingText(item) }
                        } label: {
                            mobileActionLabel("编辑内容", systemImage: "pencil")
                        }
                        .buttonStyle(.plain)
                        .disabled(locked)
                        Button {
                            performAfterDismissingMobileMenu { beginEditingTime(item) }
                        } label: {
                            mobileActionLabel("更改显示时间", systemImage: "clock")
                        }
                        .buttonStyle(.plain)
                        .disabled(locked)
                    }

                    Section(String(localized: "移动到分组")) {
                        ForEach(renderModel.sortedGroups) { group in
                            Button(group.name) {
                                if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                                    project.assignSelectedSubtitles(toGroup: group.id)
                                } else {
                                    project.assignSubtitle(id: item.id, toGroup: group.id)
                                }
                                StyleAndGroupStore.shared.setActiveGroup(group.id)
                                isShowingMobileBlockActions = false
                            }
                            .foregroundStyle(.primary)
                            .disabled(locked)
                        }
                    }

                    Section(String(localized: "设定样式")) {
                        Button(String(localized: "跟随小组样式")) {
                            if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                                project.setSelectedSubtitleStyleOverride(styleID: nil)
                            } else {
                                project.followGroupStyle(id: item.id)
                            }
                        }
                        .foregroundStyle(.primary)
                        ForEach(renderModel.styles) { style in
                            Button(style.name) {
                                if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                                    project.setSelectedSubtitleStyleOverride(styleID: style.id)
                                } else {
                                    project.setSubtitleStyleOverride(id: item.id, styleID: style.id)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }

                    Section {
                        Button {
                            isShowingMobileBlockActions = false
                            NotificationCenter.default.post(name: .stropheStartSubtitleTranslation, object: item.id)
                        } label: {
                            mobileActionLabel("从这里开始翻译", systemImage: "character.bubble")
                        }
                        .buttonStyle(.plain)
                        Button(String(localized: "删除字幕"), systemImage: "trash", role: .destructive) {
                            if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                                project.deleteSubtitles(ids: project.selectedIDs)
                            } else {
                                project.deleteSubtitle(id: item.id)
                            }
                            isShowingMobileBlockActions = false
                        }
                        .disabled(locked)
                    }
                }
                .navigationTitle(String(localized: "字幕块操作"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "完成")) { isShowingMobileBlockActions = false }
                            .foregroundStyle(.primary)
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    func performAfterDismissingMobileMenu(_ action: @escaping @MainActor () -> Void) {
        isShowingMobileBlockActions = false
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }

    func mobileActionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.stropheAccent)
                .frame(width: 22)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
    #endif

    @ViewBuilder
    func blockContextMenu(for item: SubtitleItem) -> some View {
        let locked = isLocked(item)

        Button {
            if !project.selectedIDs.contains(item.id) { project.selectedIDs.insert(item.id) }
            project.isSubtitleMultiSelecting = true
        } label: {
            Label(String(localized: "多选字幕块"), systemImage: "checklist")
        }

        Button {
            guard let groupID = renderModel.group(for: item)?.id else { return }
            project.selectedIDs = Set(renderModel.items.filter {
                renderModel.group(for: $0)?.id == groupID
            }.map(\.id))
            project.isSubtitleMultiSelecting = project.selectedIDs.count > 1
        } label: {
            Label(String(localized: "选择同组全部"), systemImage: "checkmark.square.stack")
        }

        Divider()

        Button { beginEditingText(item) } label: {
            Label(String(localized: "编辑内容"), systemImage: "pencil")
        }
        .disabled(locked)

        Button { beginEditingTime(item) } label: {
            Label(String(localized: "更改显示时间"), systemImage: "clock")
        }
        .disabled(locked)

        Menu {
            ForEach(renderModel.sortedGroups) { group in
                Button {
                    if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                        project.assignSelectedSubtitles(toGroup: group.id)
                    } else {
                        project.assignSubtitle(id: item.id, toGroup: group.id)
                    }
                } label: {
                    Label(
                        group.name,
                        systemImage: item.groupID == group.id ? "checkmark.circle.fill" : "circle"
                    )
                }
            }
        } label: {
            Label(String(localized: "移动到分组"), systemImage: "square.stack.3d.up")
        }
        .disabled(locked)

        Menu {
            Button {
                if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                    project.setSelectedSubtitleStyleOverride(styleID: nil)
                } else {
                    project.followGroupStyle(id: item.id)
                }
            } label: {
                Label(
                    String(localized: "跟随小组样式"),
                    systemImage: item.hasIndependentPresentation ? "link" : "checkmark.circle.fill"
                )
            }
            .disabled(!item.hasIndependentPresentation)

            if !renderModel.styles.isEmpty {
                Divider()
                ForEach(renderModel.styles) { style in
                    Button {
                        if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                            project.setSelectedSubtitleStyleOverride(styleID: style.id)
                        } else {
                            project.setSubtitleStyleOverride(id: item.id, styleID: style.id)
                        }
                    } label: {
                        Label(
                            style.name,
                            systemImage: item.styleID == style.id ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            }
        } label: {
            Label(String(localized: "设定样式"), systemImage: "textformat")
        }
        .disabled(locked)

        Button {
            NotificationCenter.default.post(name: .stropheStartSubtitleTranslation, object: item.id)
        } label: {
            Label(String(localized: "从这里开始翻译"), systemImage: "character.bubble")
        }

        Divider()

        Button(role: .destructive) {
            if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                project.deleteSubtitles(ids: project.selectedIDs)
            } else {
                project.deleteSubtitle(id: item.id)
            }
        } label: {
            Label(String(localized: "删除字幕"), systemImage: "trash")
        }
        .disabled(locked)
    }

    func beginEditingText(_ item: SubtitleItem) {
        editingItemID = item.id
        editingText = project.items.first(where: { $0.id == item.id })?.text ?? item.text
        isEditingText = true
    }

    func beginEditingTime(_ item: SubtitleItem) {
        guard let start = item.startTime else { return }
        editingItemID = item.id
        editingStartText = formatEditableTime(start)
        editingEndText = formatEditableTime(item.endTime ?? start + 0.1)
        isEditingTime = true
    }

    func saveEditingTime() {
        guard let editingItemID,
              let start = parseEditableTime(editingStartText),
              let end = parseEditableTime(editingEndText) else { return }
        project.updateSubtitleTime(id: editingItemID, newStartTime: start, newEndTime: end)
    }

    func formatEditableTime(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let totalSeconds = Int(clamped)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let wholeSeconds = totalSeconds % 60
        let centiseconds = Int(((clamped - Double(totalSeconds)) * 100).rounded())
        return hours > 0
            ? String(format: "%d:%02d:%02d.%02d", hours, minutes, wholeSeconds, centiseconds)
            : String(format: "%02d:%02d.%02d", minutes, wholeSeconds, centiseconds)
    }

    func parseEditableTime(_ raw: String) -> TimeInterval? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty else { return nil }
        let parts = normalized.split(separator: ":").map(String.init)
        if parts.count == 1 {
            return Double(parts[0]).map { max(0, $0) }
        }

        var total = 0.0
        for (index, part) in parts.reversed().enumerated() {
            guard let value = Double(part) else { return nil }
            total += value * pow(60, Double(index))
        }
        return max(0, total)
    }

}
