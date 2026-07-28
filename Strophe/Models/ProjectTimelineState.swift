//
//  ProjectTimelineState.swift
//  Strophe
//

import Foundation

nonisolated enum ProjectMarkerKind: String, Codable, CaseIterable, Sendable {
    case marker
    case chapter
}

nonisolated struct ProjectMarker: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var time: TimeInterval
    var title: String
    var notes: String
    var kind: ProjectMarkerKind
    var colorHex: String?

    init(
        id: UUID = UUID(),
        time: TimeInterval,
        title: String = "",
        notes: String = "",
        kind: ProjectMarkerKind = .marker,
        colorHex: String? = nil
    ) {
        self.id = id
        self.time = time
        self.title = title
        self.notes = notes
        self.kind = kind
        self.colorHex = colorHex
    }
}

nonisolated struct ProjectTimelineState: Codable, Equatable, Sendable {
    var markers: [ProjectMarker]
    var inPoint: TimeInterval?
    var outPoint: TimeInterval?
    var loopsSelection: Bool

    init(
        markers: [ProjectMarker] = [],
        inPoint: TimeInterval? = nil,
        outPoint: TimeInterval? = nil,
        loopsSelection: Bool = false
    ) {
        self.markers = markers
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.loopsSelection = loopsSelection
    }
}
