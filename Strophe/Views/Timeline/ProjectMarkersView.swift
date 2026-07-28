//
//  ProjectMarkersView.swift
//  Strophe
//

import SwiftUI

struct ProjectMarkersView: View {
    @ObservedObject var project: SubtitleProject
    @Environment(\.dismiss) private var dismiss
    @State private var editingMarker: ProjectMarker?

    var body: some View {
        #if os(macOS)
        macOSContent
        #else
        iOSContent
        #endif
    }

    #if os(macOS)
    private var macOSContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("markers_and_chapters")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.stropheText)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()
                .background(Color.stropheBorder)

            ScrollView {
                VStack(spacing: 20) {
                    rangeAndLoopCard
                    markersAndChaptersCard
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

            Divider()
                .background(Color.stropheBorder)

            // Bottom Actions
            HStack {
                Spacer()

                Button(String(localized: "cancel")) {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .tint(Color.stropheText)

                Button(String(localized: "done")) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stropheAccent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 500, height: 580)
        .background(VisualEffectView(material: .sheet, blendingMode: .behindWindow))
        .sheet(item: $editingMarker) { marker in
            MarkerEditor(marker: marker) { updated in
                project.updateMarker(updated)
            }
        }
    }
    #endif

    private var iOSContent: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    rangeAndLoopCard
                    markersAndChaptersCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle(String(localized: "markers_and_chapters"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.stropheAccent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $editingMarker) { marker in
            MarkerEditor(marker: marker) { updated in
                project.updateMarker(updated)
            }
        }
    }

    private var rangeAndLoopCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("range_and_loop")
                .font(.headline)
                .foregroundStyle(Color.stropheText)

            VStack(spacing: 10) {
                HStack {
                    Text(String(localized: "in_point"))
                        .font(.subheadline)
                    Spacer()
                    Text(project.inPoint.map(timecode) ?? "—")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(project.inPoint != nil ? Color.stropheBlue : Color.secondary)
                }

                HStack {
                    Text(String(localized: "out_point"))
                        .font(.subheadline)
                    Spacer()
                    Text(project.outPoint.map(timecode) ?? "—")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(project.outPoint != nil ? Color.orange : Color.secondary)
                }

                Toggle(
                    String(localized: "loop_in_out_range"),
                    isOn: Binding(
                        get: { project.loopsSelection },
                        set: { _ in project.toggleInOutLoop() }
                    )
                )
                .tint(Color.stropheAccent)
                .disabled(project.inPoint == nil || project.outPoint == nil)
            }

            Divider()
                .background(Color.stropheBorder)

            HStack(spacing: 10) {
                Button(String(localized: "set_in")) { project.setInPoint() }
                    .buttonStyle(.bordered)
                    .tint(Color.stropheBlue)

                Button(String(localized: "set_out")) { project.setOutPoint() }
                    .buttonStyle(.bordered)
                    .tint(Color.orange)

                Spacer()

                Button(String(localized: "clear_range"), role: .destructive) {
                    project.clearInOutPoints()
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(project.inPoint == nil && project.outPoint == nil)
            }
        }
        .padding(16)
        .background(Color.stropheSecondaryBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.stropheBorder, lineWidth: 1)
        )
    }

    private var markersAndChaptersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("markers_and_chapters")
                    .font(.headline)
                    .foregroundStyle(Color.stropheText)
                Spacer()
                Menu {
                    Button {
                        project.addMarker(kind: .marker)
                    } label: {
                        Label("add_marker", systemImage: "bookmark")
                    }
                    Button {
                        project.addMarker(kind: .chapter)
                    } label: {
                        Label("add_chapter", systemImage: "book.closed")
                    }
                } label: {
                    Label("add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .tint(Color.stropheAccent)
            }

            Divider()
                .background(Color.stropheBorder)

            if project.markers.isEmpty {
                Text("no_markers")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(project.markers) { marker in
                        HStack(spacing: 12) {
                            Image(systemName: marker.kind == .chapter ? "book.closed" : "bookmark")
                                .foregroundStyle(marker.kind == .chapter ? Color.orange : Color.stropheAccent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(marker.title.isEmpty ? title(for: marker.kind) : marker.title)
                                    .foregroundStyle(Color.stropheText)
                                Text(timecode(marker.time))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()

                            Button {
                                project.seek(to: marker.time)
                            } label: {
                                Image(systemName: "play.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.stropheAccent)

                            Button {
                                editingMarker = marker
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)

                            Button {
                                project.removeMarker(id: marker.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                        .padding(.vertical, 4)

                        if marker.id != project.markers.last?.id {
                            Divider()
                                .background(Color.stropheBorder)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.stropheSecondaryBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.stropheBorder, lineWidth: 1)
        )
    }

    private func title(for kind: ProjectMarkerKind) -> String {
        kind == .chapter ? String(localized: "chapter") : String(localized: "marker")
    }

    private func timecode(_ value: Double) -> String {
        let milliseconds = Int((max(0, value) * 1_000).rounded())
        return String(
            format: "%02d:%02d:%02d.%03d",
            milliseconds / 3_600_000,
            (milliseconds / 60_000) % 60,
            (milliseconds / 1_000) % 60,
            milliseconds % 1_000
        )
    }
}

private struct MarkerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var marker: ProjectMarker
    let onSave: (ProjectMarker) -> Void

    init(marker: ProjectMarker, onSave: @escaping (ProjectMarker) -> Void) {
        self._marker = State(initialValue: marker)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "title"), text: $marker.title)
                TextField(String(localized: "notes"), text: $marker.notes, axis: .vertical)
                Picker(String(localized: "type"), selection: $marker.kind) {
                    Text("marker").tag(ProjectMarkerKind.marker)
                    Text("chapter").tag(ProjectMarkerKind.chapter)
                }
                TextField(String(localized: "time_seconds"), value: $marker.time, format: .number)
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "edit_marker"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "save")) {
                        onSave(marker)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 300)
    }
}
