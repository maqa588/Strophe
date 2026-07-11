//
//  SubGroupPlaceholderView.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/31.
//

import SwiftUI

struct SubGroupPlaceholderView: View {
    @ObservedObject var project: SubtitleProject
    @ObservedObject var store = StyleAndGroupStore.shared

    @State private var showingAddSheet = false

    var body: some View {
        List {
            ForEach(store.groups) { group in
                groupRow(for: group)
                    .listRowInsets(EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8))
                    .contextMenu {
                        Button {
                            setActive(group.id)
                        } label: {
                            Label("set_as_default_new_group", systemImage: "circle.fill")
                        }
                        Button {
                            project.selectAllCues(in: group.id)
                        } label: {
                            Label("select_all_subtitles_in_this", systemImage: "checklist")
                        }
                        Divider()
                        Menu {
                            ForEach(store.styles) { style in
                                Button {
                                    setStyle(group.id, style: style.name)
                                } label: {
                                    if group.style == style.name {
                                        Label(style.name, systemImage: "checkmark")
                                    } else {
                                        Text(style.name)
                                    }
                                }
                            }
                        } label: {
                            Label("modify_default_style", systemImage: "textformat")
                        }
                        Button {
                            toggleOverlay(group.id)
                        } label: {
                            Label(group.isOverlayEnabled ? "hide_this_group" : "show_this_group", systemImage: group.isOverlayEnabled ? "eye.slash" : "eye")
                        }
                        Button {
                            toggleLocked(group.id)
                        } label: {
                            Label(group.isLocked ? "unlock_this_group" : "lock_this_group", systemImage: group.isLocked ? "lock.open" : "lock")
                        }
                        Divider()
                        Button {
                            project.clearText(in: group.id)
                        } label: {
                            Label("clear_text_within_group", systemImage: "text.badge.xmark")
                        }
                        Button(role: .destructive) {
                            project.deleteCues(in: group.id)
                        } label: {
                            Label("delete_subtitle_blocks_within_group", systemImage: "rectangle.stack.badge.minus")
                        }
                        Button(role: .destructive) {
                            deleteGroup(group.id)
                        } label: {
                            Label("delete_group", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .venturaFixedListRowHeight(76)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("new_group")
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            SubGroupCreateSheet(isPresented: $showingAddSheet)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func groupRow(for group: SubGroupItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Left color bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(group.color)
                    .frame(width: 3, height: 18)

                // Active radio
                Button { setActive(group.id) } label: {
                    Image(systemName: group.isActive ? "record.circle" : "circle")
                        .foregroundStyle(group.isActive ? Color.stropheAccent : Color.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("set_as_active_group")

                // Name
                HStack(spacing: 5) {
                    Text(group.name)
                        .font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(.leading)
                    if group.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(Color.stropheText)

                Spacer()

                if group.isActive {
                    Text("active")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.stropheAccent)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(Color.stropheAccent.opacity(0.12), in: Capsule())
                }
            }

            HStack(spacing: 0) {
                // Subname + cue count
                HStack(spacing: 5) {
                    Text(group.subName.isEmpty ? group.role.title : group.subName)
                    Text("dot_separator")
                    Text("\(project.cueCount(in: group.id))")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer()

                HStack(spacing: 12) {
                    // Style picker (compact)
                    Menu {
                        ForEach(store.styles) { style in
                            Button {
                                setStyle(group.id, style: style.name)
                            } label: {
                                if group.style == style.name {
                                    Label(style.name, systemImage: "checkmark")
                                } else {
                                    Text(style.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(group.style)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .medium))
                        }
                        .foregroundStyle(group.color)
                        .padding(.vertical, 2.5)
                        .padding(.horizontal, 6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()

                    // Overlay toggle
                    Button { toggleOverlay(group.id) } label: {
                        Image(systemName: group.isOverlayEnabled ? "eye" : "eye.slash")
                            .font(.system(size: 12))
                            .foregroundStyle(group.isOverlayEnabled ? Color.blue : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .help(group.isOverlayEnabled ? "hide_subtitles_of_this_group" : "show_subtitles_of_this_group")

                    // Lock toggle
                    Button { toggleLocked(group.id) } label: {
                        Image(systemName: group.isLocked ? "lock.fill" : "lock.open")
                            .font(.system(size: 12))
                            .foregroundStyle(group.isLocked ? Color.yellow : Color.secondary.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help(group.isLocked ? "unlock_this_group" : "lock_this_group")

                    // Flag
                    Button { toggleFlag(group.id) } label: {
                        Image(systemName: group.isFlagged ? "flag.fill" : "flag")
                            .font(.system(size: 12))
                            .foregroundStyle(group.isFlagged ? Color.stropheAccent : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .help(group.isFlagged ? "cancel_tag" : "tag_group")
                }
            }
            .padding(.leading, 13)
        }
        .padding(.vertical, 4)
    }



    // MARK: - Helpers

    private func setActive(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            store.setActiveGroup(id)
        }
    }

    private func setStyle(_ id: UUID, style: String) {
        if let i = store.groups.firstIndex(where: { $0.id == id }) { store.groups[i].style = style }
    }

    private func toggleOverlay(_ id: UUID) {
        if let i = store.groups.firstIndex(where: { $0.id == id }) {
            store.groups[i].isOverlayEnabled.toggle()
        }
    }

    private func toggleLocked(_ id: UUID) {
        if let i = store.groups.firstIndex(where: { $0.id == id }) {
            store.groups[i].isLocked.toggle()
        }
    }

    private func toggleFlag(_ id: UUID) {
        if let i = store.groups.firstIndex(where: { $0.id == id }) {
            store.groups[i].isFlagged.toggle()
        }
    }

    private func deleteGroup(_ id: UUID) {
        guard let i = store.groups.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = store.groups[i].isActive
        store.groups.remove(at: i)
        if wasActive, !store.groups.isEmpty { store.groups[0].isActive = true }
        let fallbackGroupID = store.activeGroupID
        for index in project.items.indices where project.items[index].groupID == id {
            project.items[index].groupID = fallbackGroupID
        }
        project.notifyChange()
    }
}

#Preview {
    SubGroupPlaceholderView(project: SubtitleProject())
        .preferredColorScheme(.dark)
}
