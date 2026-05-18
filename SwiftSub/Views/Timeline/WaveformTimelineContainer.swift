//
//  WaveformTimelineContainer.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI

struct WaveformTimelineContainer: View {
    @ObservedObject var project: SubtitleProject
    let timeline: TimelineViewDefaultContext
    let data: WaveformData
    let viewWidth: CGFloat
    let totalWidth: CGFloat
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
    
    @State private var isStartSnapped = false
    @State private var isEndSnapped = false
    
    private func triggerHapticFeedback() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        #elseif os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }
    
    let proxy: ScrollViewProxy
    
    var body: some View {
        let smoothTime = project.isScrubbing
            ? project.currentTime
            : (project.referenceTime + timeline.date.timeIntervalSince(project.referenceDate) * project.playbackRate)
                .clamped(to: 0.0...data.duration)
        
        let visibleDuration = Double(viewWidth) / pixelsPerSecond
        let smoothScrollPageStartTime = calculatePageStart(
            smoothTime: smoothTime,
            visibleDuration: visibleDuration,
            duration: data.duration
        )
        
        let snapCandidates = project.items.flatMap { [$0.startTime, $0.endTime] }.compactMap { $0 }
        
        func snapCoordinate(_ x: CGFloat) -> (val: CGFloat, snapped: Bool) {
            var closestSnap: CGFloat = x
            var minDistance = CGFloat.infinity
            let threshold: CGFloat = 12.0 // 12 像素吸附阈值
            
            for candidateTime in snapCandidates {
                let candidateX = CGFloat(candidateTime * pixelsPerSecond)
                let distance = abs(candidateX - x)
                if distance < minDistance {
                    minDistance = distance
                    closestSnap = candidateX
                }
            }
            
            if minDistance <= threshold {
                return (closestSnap, true)
            }
            return (x, false)
        }
        
        // 🌟 物理视口翻页的异步安全调度，绝对不会阻塞 UI 绘制，且能够同帧响应
        if scrollPageStartTime != smoothScrollPageStartTime {
            DispatchQueue.main.async {
                scrollPageStartTime = smoothScrollPageStartTime
                proxy.scrollTo("scroll-page-anchor", anchor: .leading)
            }
        }
        
        return ZStack(alignment: .topLeading) {
            // ── 静态与波形图层 ──────────────────────────────
            VStack(spacing: 0) {
                TimeGridView(pixelsPerSecond: pixelsPerSecond, duration: data.duration)
                    .frame(width: totalWidth, height: rulerHeight)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                guard project.editingMode == .selection else { return }
                                
                                isUserInteracting = true
                                if !project.isScrubbing {
                                    project.isScrubbing = true
                                    project.isUserSeekingTimeline = true
                                }
                                
                                let clickedTime = Double(value.location.x) / pixelsPerSecond
                                let snappedTime = project.snapToFrame(clickedTime.clamped(to: 0...data.duration))
                                
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
                
                ZStack(alignment: .leading) {
                    let renderedWidth = CGFloat(data.duration * renderedPPS)
                    let scaleX = renderedPPS > 0 ? pixelsPerSecond / renderedPPS : 1.0
                    WaveformCanvas(data: data, pixelsPerSecond: renderedPPS)
                        .frame(width: renderedWidth, height: waveHeight)
                        .scaleEffect(x: scaleX, y: 1, anchor: .leading)
                        .clipped()
                        .frame(width: totalWidth, height: waveHeight, alignment: .leading)
                    
                    SubtitleBlocksLayer(project: project, pixelsPerSecond: pixelsPerSecond, smoothTime: smoothTime)
                        .frame(width: totalWidth, height: waveHeight)
                    
                    if project.editingMode == .creation,
                       let startX = drawSubtitleStartLocation,
                       let currentX = drawSubtitleCurrentLocation {
                        let minX = min(startX, currentX)
                        let maxX = max(startX, currentX)
                        let width = max(2, maxX - minX)
                        
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.3))
                            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                            .frame(width: width, height: 30)
                            .offset(x: minX, y: 35)
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
                                        let duration = (maxX - minX) / pixelsPerSecond
                                        
                                        if duration > 0.1 {
                                            let startTime = minX / pixelsPerSecond
                                            let endTime = maxX / pixelsPerSecond
                                            project.createSubtitleBlock(startTime: startTime, endTime: endTime)
                                        }
                                    }
                                    drawSubtitleStartLocation = nil
                                    drawSubtitleCurrentLocation = nil
                                    isStartSnapped = false
                                    isEndSnapped = false
                                }
                        )
                        .simultaneousGesture(
                            SpatialTapGesture(count: 2)
                                .onEnded { value in
                                    let startTime = value.location.x / pixelsPerSecond
                                    let endTime = min(data.duration, startTime + 2.0)
                                    project.createSubtitleBlock(startTime: startTime, endTime: endTime)
                                }
                        )
                )
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard project.editingMode == .selection else { return }
                guard project.playbackRate == 0 else { return }
                
                let clickedTime = Double(location.x) / pixelsPerSecond
                let snappedTime = project.snapToFrame(clickedTime.clamped(to: 0...data.duration))
                
                project.isUserSeekingTimeline = true
                project.currentTime = snappedTime
                project.referenceTime = snappedTime
                project.referenceDate = .now
            }
            
            // ── Page Scroll Anchor View ────────────────────────
            HStack(spacing: 0) {
                Color.clear.frame(width: CGFloat(max(0.0, smoothScrollPageStartTime * pixelsPerSecond)))
                Color.clear.frame(width: 1, height: 1).id("scroll-page-anchor")
                Spacer(minLength: 0)
            }
            
            // ── 播放头：完全锁频在 100Hz 运动，丝毫不抖 ──
            DraggablePlayhead(
                currentTime: $project.currentTime,
                isScrubbing: $project.isScrubbing,
                isDragging: $isDraggingPlayhead,
                dragStartTime: $dragStartTime,
                pixelsPerSecond: pixelsPerSecond,
                duration: data.duration,
                project: project
            )
            .allowsHitTesting(project.editingMode == .selection)
            .frame(height: rulerHeight + waveHeight)
            .offset(x: CGFloat(max(0.0, smoothTime * pixelsPerSecond)))
        }
        .frame(width: totalWidth, height: rulerHeight + waveHeight)
    }
    
    private func calculatePageStart(smoothTime: Double, visibleDuration: Double, duration: Double) -> Double {
        if isDraggingPlayhead || isUserInteracting {
            return scrollPageStartTime
        } else {
            let pageIndex = Int(smoothTime / max(0.001, visibleDuration))
            let target = Double(pageIndex) * visibleDuration
            return max(0.0, min(max(0.0, duration - visibleDuration), target))
        }
    }
}
