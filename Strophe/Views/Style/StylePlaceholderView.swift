//
//  StylePlaceholderView.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/31.
//

import SwiftUI

struct StylePlaceholderView: View {
    @ObservedObject var project: SubtitleProject
    @ObservedObject var store = StyleAndGroupStore.shared
    @State private var selectedStyleId: UUID? = nil

    @State private var showingAddSheet = false
    @State private var showingEditSheet = false

    private let availableColors: [Color] = [
        .white,
        Color(red: 0.0, green: 0.8, blue: 0.9),
        Color(red: 0.5, green: 0.85, blue: 0.0),
        Color(red: 1.0, green: 0.65, blue: 0.0),
        Color(red: 1.0, green: 0.1, blue: 0.6),
        Color(red: 0.6, green: 0.3, blue: 0.9)
    ]

    var body: some View {
        List(store.styles, id: \.id, selection: $selectedStyleId) { style in
            styleRow(for: style)
                .tag(style.id)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .contextMenu {
                    Button {
                        selectedStyleId = style.id
                        showingEditSheet = true
                    } label: {
                        Label("edit_style", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        let copy = duplicate(style)
                        store.styles.append(copy)
                        selectedStyleId = copy.id
                    } label: {
                        Label("copy", systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button(role: .destructive) {
                        deleteStyle(id: style.id)
                    } label: {
                        Label("delete", systemImage: "trash")
                    }
                }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .venturaFixedListRowHeight(44)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("new_style", systemImage: "plus")
                    }

                    Divider()

                    Button {
                        if selectedStyleId != nil {
                            showingEditSheet = true
                        }
                    } label: {
                        Label("edit_style", systemImage: "pencil")
                    }
                    .disabled(selectedStyleId == nil)

                    Button {
                        if let id = selectedStyleId,
                           let style = store.styles.first(where: { $0.id == id }) {
                            let copy = duplicate(style)
                            store.styles.append(copy)
                            selectedStyleId = copy.id
                        }
                    } label: {
                        Label("copy_style", systemImage: "doc.on.doc")
                    }
                    .disabled(selectedStyleId == nil)

                    Divider()

                    Button(role: .destructive) {
                        if let id = selectedStyleId { deleteStyle(id: id) }
                    } label: {
                        Label("delete_style", systemImage: "trash")
                    }
                    .disabled(selectedStyleId == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .help("style_operations")
            }
        }
        .onAppear {
            if selectedStyleId == nil { selectedStyleId = store.styles.first?.id }
        }
        .sheet(isPresented: $showingAddSheet) {
            StyleCreateSheet(isPresented: $showingAddSheet, selectedStyleId: $selectedStyleId)
        }
        .sheet(isPresented: $showingEditSheet) {
            StyleEditSheet(
                isPresented: $showingEditSheet,
                selectedStyleId: $selectedStyleId,
                project: project
            )
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func styleRow(for style: SubgroupStyle) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(style.color == .white ? Color.clear : style.color.opacity(0.25))
                Circle()
                    .strokeBorder(
                        style.color == .white ? Color.secondary.opacity(0.5) : style.color,
                        lineWidth: style.isGlowing ? 2 : 1.5
                    )
                    .glow(
                        color: style.isGlowing ? style.color.opacity(0.7) : .clear,
                        radius: style.isGlowing ? 5 : 0
                    )
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(style.name)
                    .font(.system(size: 13, weight: .medium))
                Text(style.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func deleteStyle(id: UUID) {
        guard let index = store.styles.firstIndex(where: { $0.id == id }) else { return }
        let deletedName = store.styles[index].name
        store.styles.remove(at: index)
        let fallbackStyle = store.styles.first?.name ?? "Default"
        for groupIndex in store.groups.indices where store.groups[groupIndex].style == deletedName {
            store.groups[groupIndex].style = fallbackStyle
        }
        selectedStyleId = store.styles.isEmpty ? nil : store.styles[max(0, index - 1)].id
    }

    private func duplicate(_ style: SubgroupStyle) -> SubgroupStyle {
        var copy = style
        copy.id = UUID()
        copy.name = String(localized: "style_name_copy_suffix_pattern \(style.name)")
        return copy
    }

}

#Preview {
    StylePlaceholderView(project: SubtitleProject())
        .preferredColorScheme(.dark)
}
