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
                            mobileActionLabel("multi_select_subtitle_blocks", systemImage: "checklist")
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
                            mobileActionLabel("select_all_in_group", systemImage: "checkmark.square.stack")
                        }
                        .buttonStyle(.plain)
                        Button {
                            performAfterDismissingMobileMenu { beginEditingText(item) }
                        } label: {
                            mobileActionLabel("edit_content", systemImage: "pencil")
                        }
                        .buttonStyle(.plain)
                        .disabled(locked)
                        Button {
                            performAfterDismissingMobileMenu { beginEditingTime(item) }
                        } label: {
                            mobileActionLabel("change_display_time", systemImage: "clock")
                        }
                        .buttonStyle(.plain)
                        .disabled(locked)
                    }

                    Section(String(localized: "move_to_group")) {
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

                    Section(String(localized: "set_style")) {
                        Button(String(localized: "follow_group_style")) {
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
                            mobileActionLabel("start_translation_from_here", systemImage: "character.bubble")
                        }
                        .buttonStyle(.plain)
                        Button(String(localized: "delete_subtitle"), systemImage: "trash", role: .destructive) {
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
                .navigationTitle(String(localized: "subtitle_block_operations"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "done")) { isShowingMobileBlockActions = false }
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
            Label(String(localized: "multi_select_subtitle_blocks"), systemImage: "checklist")
        }

        Button {
            guard let groupID = renderModel.group(for: item)?.id else { return }
            project.selectedIDs = Set(renderModel.items.filter {
                renderModel.group(for: $0)?.id == groupID
            }.map(\.id))
            project.isSubtitleMultiSelecting = project.selectedIDs.count > 1
        } label: {
            Label(String(localized: "select_all_in_group"), systemImage: "checkmark.square.stack")
        }

        Divider()

        Button { beginEditingText(item) } label: {
            Label(String(localized: "edit_content"), systemImage: "pencil")
        }
        .disabled(locked)

        Button { beginEditingTime(item) } label: {
            Label(String(localized: "change_display_time"), systemImage: "clock")
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
            Label(String(localized: "move_to_group"), systemImage: "square.stack.3d.up")
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
                    String(localized: "follow_group_style"),
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
            Label(String(localized: "set_style"), systemImage: "textformat")
        }
        .disabled(locked)

        Button {
            NotificationCenter.default.post(name: .stropheStartSubtitleTranslation, object: item.id)
        } label: {
            Label(String(localized: "start_translation_from_here"), systemImage: "character.bubble")
        }

        Divider()

        Button(role: .destructive) {
            if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                project.deleteSubtitles(ids: project.selectedIDs)
            } else {
                project.deleteSubtitle(id: item.id)
            }
        } label: {
            Label(String(localized: "delete_subtitle"), systemImage: "trash")
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
