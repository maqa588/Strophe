//
//  SubtitleProject+TimelineAnnotations.swift
//  Strophe
//

import Foundation

extension SubtitleProject {
    func addMarker(
        at time: TimeInterval? = nil,
        kind: ProjectMarkerKind = .marker,
        title: String = ""
    ) {
        let oldState = currentTimelineState
        let resolvedTime = snapToFrame(max(0, time ?? currentTime))
        let fallbackTitle = kind == .chapter
            ? String(localized: "chapter")
            : String(localized: "marker")
        markers.append(
            ProjectMarker(
                time: resolvedTime,
                title: title.isEmpty ? fallbackTitle : title,
                kind: kind
            )
        )
        markers.sort { $0.time < $1.time }
        registerTimelineUndo(oldState)
        notifyChange()
    }

    func updateMarker(_ marker: ProjectMarker) {
        guard let index = markers.firstIndex(where: { $0.id == marker.id }) else { return }
        let oldState = currentTimelineState
        var updated = marker
        updated.time = snapToFrame(max(0, updated.time))
        markers[index] = updated
        markers.sort { $0.time < $1.time }
        registerTimelineUndo(oldState)
        notifyChange()
    }

    func removeMarker(id: UUID) {
        guard markers.contains(where: { $0.id == id }) else { return }
        let oldState = currentTimelineState
        markers.removeAll { $0.id == id }
        registerTimelineUndo(oldState)
        notifyChange()
    }

    func setInPoint(at time: TimeInterval? = nil) {
        let oldState = currentTimelineState
        inPoint = snapToFrame(max(0, time ?? currentTime))
        if let outPoint, outPoint <= inPoint ?? 0 {
            self.outPoint = nil
            loopsSelection = false
        }
        registerTimelineUndo(oldState)
        notifyChange()
    }

    func setOutPoint(at time: TimeInterval? = nil) {
        let candidate = snapToFrame(max(0, time ?? currentTime))
        guard inPoint == nil || candidate > inPoint! else { return }
        let oldState = currentTimelineState
        outPoint = candidate
        registerTimelineUndo(oldState)
        notifyChange()
    }

    func clearInOutPoints() {
        guard inPoint != nil || outPoint != nil || loopsSelection else { return }
        let oldState = currentTimelineState
        inPoint = nil
        outPoint = nil
        loopsSelection = false
        registerTimelineUndo(oldState)
        notifyChange()
    }

    func toggleInOutLoop() {
        guard let inPoint, let outPoint, outPoint > inPoint else { return }
        loopsSelection.toggle()
        if loopsSelection, currentTime < inPoint || currentTime >= outPoint {
            seek(to: inPoint)
        }
        notifyChange()
    }

    func toggleCurrentSubtitleLoop() {
        if loopsSelection {
            loopsSelection = false
            notifyChange()
            return
        }
        guard let cue = currentLoopCue,
              let start = cue.startTime,
              let end = cue.endTime,
              end > start else {
            return
        }
        let oldState = currentTimelineState
        inPoint = start
        outPoint = end
        loopsSelection = true
        registerTimelineUndo(oldState)
        if currentTime < start || currentTime >= end {
            seek(to: start)
        }
        notifyChange()
    }

    func seekToAdjacentMarker(forward: Bool) {
        let tolerance = max(0.001, videoFrameRate > 0 ? 0.5 / videoFrameRate : 0.001)
        let target: Double?
        if forward {
            target = markers.first(where: { $0.time > currentTime + tolerance })?.time
        } else {
            target = markers.last(where: { $0.time < currentTime - tolerance })?.time
        }
        if let target { seek(to: target) }
    }

    func transportJogBackward() {
        pause()
        let frames = max(1, Int((videoFrameRate > 0 ? videoFrameRate : 30) / 4))
        seekByFrames(-frames)
    }

    func transportStop() {
        pause()
    }

    func transportShuttleForward() {
        guard let engine = activeEngine else { return }
        let currentRate = engine.rate
        let nextRate: Double
        switch currentRate {
        case ..<0.75: nextRate = 1
        case ..<1.5: nextRate = 2
        case ..<3: nextRate = 4
        default: nextRate = 1
        }
        targetSpeed = nextRate
        engine.rate = nextRate
        playbackRate = nextRate
        referenceTime = engine.currentTime
        referenceDate = .now
    }

    private var currentLoopCue: SubtitleItem? {
        if let selected = items
            .filter({ selectedIDs.contains($0.id) })
            .sorted(by: stableSubtitleSort)
            .first {
            return selected
        }
        if let active = items.first(where: {
            guard let start = $0.startTime, let end = $0.endTime else { return false }
            return start <= currentTime && currentTime < end
        }) {
            return active
        }
        return items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    private var currentTimelineState: ProjectTimelineState {
        ProjectTimelineState(
            markers: markers,
            inPoint: inPoint,
            outPoint: outPoint,
            loopsSelection: loopsSelection
        )
    }

    private func applyTimelineState(_ state: ProjectTimelineState) {
        markers = state.markers
        inPoint = state.inPoint
        outPoint = state.outPoint
        loopsSelection = state.loopsSelection
        notifyChange()
    }

    private func registerTimelineUndo(_ oldState: ProjectTimelineState) {
        undoManager.registerUndo(withTarget: self) { project in
            let redoState = project.currentTimelineState
            project.applyTimelineState(oldState)
            project.registerTimelineUndo(redoState)
        }
        undoManager.setActionName(String(localized: "edit_timeline_annotations"))
    }
}
