//
//  WaveformTimelineContainer.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI

struct WaveformTimelineContainer: View {
    @ObservedObject var project: SubtitleProject
    @ObservedObject var data: WaveformData
    let viewWidth: CGFloat
    let totalWidth: CGFloat
    let workspaceDuration: Double
    let visibleStartTime: Double
    let rulerHeight: CGFloat
    let waveHeight: CGFloat
    
    @Binding var pixelsPerSecond: Double
    @Binding var renderedPPS: Double
    @Binding var scrollPageStartTime: Double
    @Binding var isDraggingPlayhead: Bool
    @Binding var isUserInteracting: Bool
    
    @Binding var drawSubtitleStartLocation: CGFloat?
    @Binding var drawSubtitleCurrentLocation: CGFloat?
    @Binding var dragStartTime: Double
    @Binding var trackVerticalScale: CGFloat
    @Binding var trackVerticalOffset: CGFloat
    
    @State private var isStartSnapped = false
    @State private var isEndSnapped = false
    @State private var creationTargetGroupID: UUID?
    
    private func triggerHapticFeedback() {
        #if os(macOS)
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }
        #elseif os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }
    
    
    private var currentTimeBinding: Binding<Double> {
        Binding(
            get: { project.currentTime },
            set: { project.currentTime = $0 }
        )
    }
    
    private func snapCoordinate(_ x: CGFloat, threshold: CGFloat = 12.0) -> (val: CGFloat, snapped: Bool) {
        let safePixelsPerSecond = pixelsPerSecond.isFinite ? max(0.001, pixelsPerSecond) : 50.0
        let time = Double(x) / safePixelsPerSecond
        if let candidateTime = project.timelineIndex.nearestSnapPoint(to: time), candidateTime.isFinite {
            let candidateX = CGFloat(candidateTime * safePixelsPerSecond)
            if abs(candidateX - x) <= threshold {
                return (candidateX, true)
            }
        }
        return (x, false)
    }
    
    var body: some View {
        let safeDuration = data.duration.isFinite ? max(0.0, data.duration) : 0.0
        let safePixelsPerSecond = pixelsPerSecond.isFinite ? max(0.001, pixelsPerSecond) : 50.0
        let safeRenderedPPS = renderedPPS.isFinite ? max(0.001, renderedPPS) : safePixelsPerSecond
        let safeViewWidth = viewWidth.isFinite ? max(1.0, viewWidth) : 1.0
        let safeTotalWidth = totalWidth.isFinite ? max(1.0, totalWidth) : 1.0
        let safeWorkspaceDuration = workspaceDuration.isFinite ? max(safeDuration, workspaceDuration) : safeDuration
        return ZStack(alignment: .topLeading) {
            // ── 静态与波形图层 ──────────────────────────────
            VStack(spacing: 0) {
                TimeGridView(
                    pixelsPerSecond: safePixelsPerSecond,
                    duration: safeDuration,
                    visibleStartTime: visibleStartTime,
                    viewWidth: safeViewWidth
                )
                    .frame(width: safeTotalWidth, height: rulerHeight)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                guard project.editingMode == .selection else { return }
                                
                                isUserInteracting = true
                                if !project.isScrubbing {
                                    project.isScrubbing = true
                                    project.isUserSeekingTimeline = false
                                }
                                
                                let clickedTime = Double(value.location.x) / safePixelsPerSecond
                                let snappedTime = project.snapToFrame(clickedTime.clamped(to: 0...safeDuration))
                                
                                project.currentTime = snappedTime
                            }
                            .onEnded { _ in
                                guard project.editingMode == .selection else { return }
                                project.isScrubbing = false
                                project.isUserSeekingTimeline = false
                                project.referenceTime = project.currentTime
                                project.referenceDate = .now
                                
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    isUserInteracting = false
                                }
                            }
                    )
                
                ZStack(alignment: .topLeading) {
                    let renderedWidth = CGFloat(safeDuration * safeRenderedPPS)
                    let scaleX = safePixelsPerSecond / safeRenderedPPS
                    WaveformCanvas(data: data, pixelsPerSecond: safeRenderedPPS)
                        .frame(width: renderedWidth, height: SubtitleTimelineTrackMetrics.viewportHeight)
                        .scaleEffect(x: scaleX, y: 1, anchor: .leading)
                        .clipped()
                        .frame(width: safeTotalWidth, height: waveHeight, alignment: .topLeading)
                    
                    SubtitleBlocksLayer(
                        project: project,
                        pixelsPerSecond: safePixelsPerSecond,
                        visibleStartTime: visibleStartTime,
                        viewWidth: safeViewWidth,
                        workspaceDuration: safeWorkspaceDuration,
                        scrollPageStartTime: $scrollPageStartTime,
                        trackVerticalScale: $trackVerticalScale,
                        trackVerticalOffset: $trackVerticalOffset
                    )
                    .frame(width: safeTotalWidth, height: waveHeight)
                    
                    if project.editingMode == .creation,
                       let startX = drawSubtitleStartLocation,
                       let currentX = drawSubtitleCurrentLocation {
                        let minX = min(startX, currentX)
                        let maxX = max(startX, currentX)
                        let width = max(2, maxX - minX)
                        
                        Rectangle()
                            .fill(Color.stropheBlue.opacity(0.3))
                            .overlay(Rectangle().stroke(Color.stropheBlue, lineWidth: 1))
                            .frame(
                                width: width,
                                height: SubtitleTimelineTrackMetrics.scaledBlockHeight(trackVerticalScale)
                            )
                            .offset(x: minX, y: creationTargetBlockY)
                    }
                }
                .overlay(
                    Color.black.opacity(0.001)
                        .allowsHitTesting(project.editingMode == .creation)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    let snapStart = snapCoordinate(value.startLocation.x)
                                    if drawSubtitleStartLocation == nil {
                                        drawSubtitleStartLocation = snapStart.val
                                        creationTargetGroupID = trackGroup(at: value.startLocation.y)?.id
                                        if let creationTargetGroupID {
                                            StyleAndGroupStore.shared.setActiveGroup(creationTargetGroupID)
                                        }
                                    }
                                    if snapStart.snapped && !isStartSnapped {
                                        triggerHapticFeedback()
                                    }
                                    isStartSnapped = snapStart.snapped
                                    
                                    let snapEnd = snapCoordinate(value.location.x)
                                    drawSubtitleCurrentLocation = snapEnd.val
                                    if snapEnd.snapped && !isEndSnapped {
                                        triggerHapticFeedback()
                                    }
                                    isEndSnapped = snapEnd.snapped
                                }
                                .onEnded { value in
                                    if let startX = drawSubtitleStartLocation {
                                        let endX = snapCoordinate(value.location.x).val
                                        let minX = min(startX, endX)
                                        let maxX = max(startX, endX)
                                        let duration = (maxX - minX) / safePixelsPerSecond
                                        
                                        if duration > 0.1 {
                                            let startTime = (minX / safePixelsPerSecond).clamped(to: 0...safeWorkspaceDuration)
                                            let endTime = (maxX / safePixelsPerSecond).clamped(to: 0...safeWorkspaceDuration)
                                            project.createSubtitleBlock(
                                                startTime: startTime,
                                                endTime: endTime,
                                                groupID: creationTargetGroupID
                                            )
                                        }
                                    }
                                    drawSubtitleStartLocation = nil
                                    drawSubtitleCurrentLocation = nil
                                    creationTargetGroupID = nil
                                    isStartSnapped = false
                                    isEndSnapped = false
                                }
                        )
                        .simultaneousGesture(
                            SpatialTapGesture(count: 2)
                                .onEnded { value in
                                    let startTime = (value.location.x / safePixelsPerSecond).clamped(to: 0...safeWorkspaceDuration)
                                    let endTime = min(safeWorkspaceDuration, startTime + 2.0)
                                    let targetGroupID = trackGroup(at: value.location.y)?.id
                                    if let targetGroupID {
                                        StyleAndGroupStore.shared.setActiveGroup(targetGroupID)
                                    }
                                    project.createSubtitleBlock(
                                        startTime: startTime,
                                        endTime: endTime,
                                        groupID: targetGroupID
                                    )
                                }
                        )
                )
            }
            .contentShape(Rectangle())

            ScrollViewTracker(scrollPageStartTime: scrollPageStartTime, pixelsPerSecond: safePixelsPerSecond)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            
            // ── 播放头：完全锁频在 100Hz 运动，丝毫不抖 ──
            TimelineView(.animation) { timeline in
                let smoothTime = playbackTime(at: timeline.date, duration: safeDuration)
                let visibleDuration = Double(safeViewWidth) / safePixelsPerSecond
                let smoothScrollPageStartTime = calculatePageStart(
                    smoothTime: smoothTime,
                    visibleDuration: visibleDuration,
                    duration: safeDuration
                )

                DraggablePlayhead(
                    currentTime: currentTimeBinding,
                    isScrubbing: $project.isScrubbing,
                    isDragging: $isDraggingPlayhead,
                    dragStartTime: $dragStartTime,
                    pixelsPerSecond: safePixelsPerSecond,
                    duration: safeDuration,
                    project: project
                )
                .allowsHitTesting(project.editingMode == .selection)
                .frame(height: rulerHeight + waveHeight)
                .offset(x: CGFloat(max(0.0, smoothTime * safePixelsPerSecond)))
                .task(id: smoothScrollPageStartTime) {
                    guard project.playbackRate != 0 else { return }
                    guard scrollPageStartTime != smoothScrollPageStartTime else { return }
                    scrollPageStartTime = smoothScrollPageStartTime
                }
            }
        }
        .frame(width: safeTotalWidth, height: rulerHeight + waveHeight)
    }

    private var creationTargetBlockY: CGFloat {
        let store = StyleAndGroupStore.shared
        let tracks = store.sortedGroups.filter(\.isOverlayEnabled)
        let targetGroupID = creationTargetGroupID ?? store.activeGroupID
        let activeIndex = tracks.firstIndex(where: { $0.id == targetGroupID }) ?? 0
        return SubtitleTimelineTrackMetrics.blockY(
            trackIndex: activeIndex,
            scale: trackVerticalScale,
            offset: trackVerticalOffset
        )
    }

    private func trackGroup(at y: CGFloat) -> SubGroupItem? {
        let tracks = StyleAndGroupStore.shared.sortedGroups.filter(\.isOverlayEnabled)
        let index = SubtitleTimelineTrackMetrics.trackIndex(
            at: y,
            scale: trackVerticalScale,
            offset: trackVerticalOffset
        )
        guard tracks.indices.contains(index) else { return nil }
        return tracks[index]
    }

    private func playbackTime(at date: Date, duration: Double) -> Double {
        let rawTime = project.isScrubbing
            ? project.currentTime
            : (project.referenceTime + date.timeIntervalSince(project.referenceDate) * project.playbackRate)
        return rawTime.isFinite
            ? rawTime.clamped(to: 0.0...duration)
            : project.currentTime.clampedFinite(to: 0.0...duration)
    }
    
    private func calculatePageStart(smoothTime: Double, visibleDuration: Double, duration: Double) -> Double {
        if isDraggingPlayhead || isUserInteracting {
            return scrollPageStartTime.isFinite ? scrollPageStartTime : 0
        }
        
        guard smoothTime.isFinite, visibleDuration.isFinite, duration.isFinite else { return 0 }
        
        let currentStart = visibleStartTime.isFinite ? visibleStartTime : 0
        let currentEnd = currentStart + visibleDuration
        
        // If playhead is inside the current visible page, don't trigger auto-scroll
        if smoothTime >= currentStart && smoothTime <= currentEnd {
            return scrollPageStartTime.isFinite ? scrollPageStartTime : 0
        } else {
            // Playhead went off-screen. Scroll to the page containing smoothTime
            let pageIndex = Int(smoothTime / max(0.001, visibleDuration))
            let target = Double(pageIndex) * visibleDuration
            return max(0.0, min(max(0.0, duration - visibleDuration), target))
        }
    }
}
