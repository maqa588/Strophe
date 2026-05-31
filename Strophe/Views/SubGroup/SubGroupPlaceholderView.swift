//
//  SubGroupPlaceholderView.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/31.
//

import SwiftUI

struct SubGroupPlaceholderView: View {
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
                            Label("设为活动分组", systemImage: "circle.fill")
                        }
                        Divider()
                        Button(role: .destructive) {
                            deleteGroup(group.id)
                        } label: {
                            Label("删除分组", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("新建分组")
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            SubGroupCreateSheet(isPresented: $showingAddSheet)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func groupRow(for group: SubGroupItem) -> some View {
        HStack(spacing: 10) {
            // Left color bar
            RoundedRectangle(cornerRadius: 2)
                .fill(group.color)
                .frame(width: 3, height: 34)

            // Active radio
            Button { setActive(group.id) } label: {
                Image(systemName: group.isActive ? "record.circle" : "circle")
                    .foregroundStyle(group.isActive ? Color.stropheAccent : Color.secondary)
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .help("设为活动分组")

            // Name + subname
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.system(size: 13, weight: .medium))
                Text(group.subName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

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
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .medium))
                }
                .foregroundStyle(group.color)
                .padding(.vertical, 3)
                .padding(.horizontal, 7)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .fixedSize()

            // Overlay toggle
            Button { toggleOverlay(group.id) } label: {
                Image(systemName: group.isOverlayEnabled
                      ? "square.2.layers.3d"
                      : "square.2.layers.3d.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(group.isOverlayEnabled ? Color.blue : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help(group.isOverlayEnabled ? "隐藏此组字幕" : "显示此组字幕")

            // Flag
            Button { toggleFlag(group.id) } label: {
                Image(systemName: group.isFlagged ? "flag.fill" : "flag")
                    .font(.system(size: 13))
                    .foregroundStyle(group.isFlagged ? Color.stropheAccent : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help(group.isFlagged ? "取消标记" : "标记分组")
        }
    }



    // MARK: - Helpers

    private func setActive(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            for i in store.groups.indices { store.groups[i].isActive = store.groups[i].id == id }
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
    }
}

#Preview {
    SubGroupPlaceholderView()
        .preferredColorScheme(.dark)
}
