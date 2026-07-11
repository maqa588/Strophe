//
//  WaveformTimelineView.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/16.
//

import SwiftUI

private let timelineScrollCoordinateSpaceName = "timelineScrollCoordinateSpace"

struct WaveformTimelineView: View {
    @ObservedObject var project: SubtitleProject
    @ObservedObject private var groupStore = StyleAndGroupStore.shared
    
    // 渲染参数
    @State private var pixelsPerSecond: Double = 50
    /// 上一次 Canvas 实际绘制时使用的 PPS（缩放防抖用）
    @State private var renderedPPS: Double = 50
    @State private var playheadID = "playhead-anchor"
    @State private var isDraggingPlayhead = false
    @State private var dragStartTime: Double = 0
    @State private var isUserInteracting = false // 是否正在手动操作
    @State private var scrollPageStartTime: Double = 0 // 播放标尺视口分页起始时间
    @State private var viewportStartTime: Double = 0 // 当前 ScrollView 实际可见起始时间
    @State private var zoomDebounceTask: Task<Void, Never>? = nil // 缩放防抖任务
    
    // Draw Subtitle State
    @State private var drawSubtitleStartLocation: CGFloat? = nil
    @State private var drawSubtitleCurrentLocation: CGFloat? = nil
    
    // Real-time dynamic layout width state
    @State private var availableWidth: CGFloat = 800
    @State private var trackVerticalScale: CGFloat = 0.78
    @State private var trackVerticalOffset: CGFloat = 0

    #if os(iOS)
    @State private var gestureZoomBasePPS: Double = 50.0
    @State private var gestureZoomBaseTrackScale: CGFloat = 0.78
    @State private var isTouchZooming = false
    #endif
    
    private var isCompact: Bool {
        return availableWidth < 720
    }
    
    var body: some View {
        let viewWidth = availableWidth.isFinite ? max(1, availableWidth) : 800
        let rawDuration = project.waveformData?.duration ?? 1
        let duration = rawDuration.isFinite ? max(1, rawDuration) : 1
        let minPPS = max(0.001, Double(viewWidth) / duration)
        let maxPPS = max(minPPS, Double(viewWidth) / 5.0)

        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.stropheTimelineDivider)
                .frame(height: 1)
            
            // MARK: - Extracted Timeline Toolbar
            TimelineToolbarView(project: project)
                .fixedSize(horizontal: false, vertical: true)

            // MARK: - Timeline Core
            if let data = project.waveformData {
                let safeDataDuration = data.duration.isFinite ? max(0, data.duration) : 0
                let safePPS = pixelsPerSecond.isFinite ? max(0.001, pixelsPerSecond) : minPPS
                let rulerHeight: CGFloat = 25
                let waveHeight = SubtitleTimelineTrackMetrics.totalHeight(
                    trackCount: visibleTimelineTrackCount
                )

                GeometryReader { timelineGeo in
                    let contentWidth = max(1, timelineGeo.size.width)
                    let visibleDuration = Double(max(1, contentWidth)) / safePPS
                    let trailingWorkspaceDuration = max(8.0, visibleDuration * 0.75)
                    let timelineWorkspaceDuration = safeDataDuration + trailingWorkspaceDuration
                    // Never let the timeline content become narrower than its viewport
                    // during split-view/window resizing; otherwise the uncovered right
                    // side appears as a black rendering gap until the next zoom event.
                    let totalWidth = max(contentWidth, CGFloat(max(1, timelineWorkspaceDuration * safePPS)))

                    ZStack(alignment: .top) {
                        ScrollView(.horizontal, showsIndicators: true) {
                            ZStack(alignment: .topLeading) {
                                scrollOffsetReader(pixelsPerSecond: safePPS, duration: timelineWorkspaceDuration, viewWidth: contentWidth)

                                WaveformTimelineContainer(
                                    project: project,
                                    data: data,
                                    viewWidth: contentWidth,
                                    totalWidth: totalWidth,
                                    workspaceDuration: timelineWorkspaceDuration,
                                    visibleStartTime: viewportStartTime,
                                    rulerHeight: rulerHeight,
                                    waveHeight: waveHeight,
                                    pixelsPerSecond: $pixelsPerSecond,
                                    renderedPPS: $renderedPPS,
                                    scrollPageStartTime: $scrollPageStartTime,
                                    isDraggingPlayhead: $isDraggingPlayhead,
                                    isUserInteracting: $isUserInteracting,
                                    drawSubtitleStartLocation: $drawSubtitleStartLocation,
                                    drawSubtitleCurrentLocation: $drawSubtitleCurrentLocation,
                                    dragStartTime: $dragStartTime,
                                    trackVerticalScale: $trackVerticalScale,
                                    trackVerticalOffset: $trackVerticalOffset
                                )
                            }
                            .padding(.bottom, 6)
                            .stropheOnChange(of: pixelsPerSecond) { _ in
                                keepPlayheadInView(viewWidth: Double(contentWidth), duration: timelineWorkspaceDuration)
                            }
                        }
                        // ── 宽度同步：内层 GR 永远在 NavigationSplitView 内容区域内部，
                        // 读到的 contentWidth 一定不含侧栏，这里同步给 availableWidth ──
                        .onAppear {
                            applyContentWidth(contentWidth, duration: data.duration)
                        }
                        .stropheOnChange(of: contentWidth) { newWidth in
                            applyContentWidth(newWidth, duration: data.duration)
                        }
                        .coordinateSpace(name: timelineScrollCoordinateSpaceName)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 5)
                                .onChanged { _ in
                                    isUserInteracting = true
                                }
                                .onEnded { _ in
                                    isUserInteracting = false
                                }
                        )
                        #if os(iOS)
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    if !isTouchZooming {
                                        isTouchZooming = true
                                        gestureZoomBasePPS = pixelsPerSecond
                                        gestureZoomBaseTrackScale = trackVerticalScale
                                    }
                                    let newPPS = gestureZoomBasePPS * Double(value)
                                    pixelsPerSecond = min(maxPPS, max(minPPS, newPPS))
                                    trackVerticalScale = SubtitleTimelineTrackMetrics.clampedScale(
                                        gestureZoomBaseTrackScale * sqrt(CGFloat(value))
                                    )
                                    scheduleCanvasRedraw()
                                }
                                .onEnded { _ in
                                    guard isTouchZooming else { return }
                                    isTouchZooming = false
                                    gestureZoomBasePPS = pixelsPerSecond
                                    gestureZoomBaseTrackScale = trackVerticalScale
                                    renderedPPS = pixelsPerSecond
                                }
                        )
                        #endif
                        #if os(macOS)
                        .onContinuousHover { _ in }
                        #endif
                        .background(
                            ScrollZoomModifier(
                                pixelsPerSecond: $pixelsPerSecond,
                                minPPS: minPPS,
                                maxPPS: maxPPS,
                                playheadTime: project.currentTime,
                                scrollPageStartTime: $scrollPageStartTime,
                                trackVerticalScale: $trackVerticalScale,
                                trackVerticalOffset: $trackVerticalOffset,
                                trackCount: visibleTimelineTrackCount,
                                onCommit: scheduleCanvasRedraw
                            )
                        )
                        
                        #if os(iOS)
                        if project.editingMode == .creation {
                            SlapButtonsOverlay(project: project)
                        }
                        #endif
                    }
                }
                .frame(height: rulerHeight + waveHeight + 6)

            } else {
                emptyPlaceholder
            }
        }
        .padding(.bottom, 12)
        .environment(\.layoutDirection, .leftToRight)
        .stropheOnChange(of: project.videoURL) { _ in
            scrollPageStartTime = 0
            viewportStartTime = 0
        }
        .stropheOnChange(of: project.waveformData?.duration) { duration in
            guard let duration, duration.isFinite else { return }
            // 宽度在 applyContentWidth 里已经正确，这里只重置滚动状态
            scrollPageStartTime = 0
            viewportStartTime = 0
            let safeWidth = availableWidth.isFinite ? max(1, availableWidth) : 800
            let safeDuration = max(1, duration)
            pixelsPerSecond = Double(safeWidth) / safeDuration
            renderedPPS = pixelsPerSecond
        }
        .stropheOnChange(of: project.currentTime) { _ in
            guard project.playbackRate == 0 else { return }
            guard !project.isScrubbing && !isDraggingPlayhead && !isUserInteracting else { return }
            let rawDuration = project.waveformData?.duration ?? 1
            let duration = rawDuration.isFinite ? max(1, rawDuration) : 1
            centerPlayheadIfNeeded(viewWidth: Double(availableWidth), duration: duration)
        }
        .frame(height: isCompact ? 236 : 200)
        .padding(.bottom, bottomScrollerClearance)
        .frame(maxWidth: .infinity)
        .background(Color.stropheSecondaryBackground)
    }

    private var bottomScrollerClearance: CGFloat {
        #if os(macOS)
        return 8
        #else
        return 0
        #endif
    }

    private var visibleTimelineTrackCount: Int {
        max(1, groupStore.sortedGroups.filter(\.isOverlayEnabled).count)
    }

    private func scrollOffsetReader(pixelsPerSecond: Double, duration: Double, viewWidth: CGFloat) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    updateVisibleScrollStart(proxy: proxy, pixelsPerSecond: pixelsPerSecond, duration: duration, viewWidth: viewWidth)
                }
                .stropheOnChange(of: proxy.frame(in: .named(timelineScrollCoordinateSpaceName)).minX) { _ in
                    updateVisibleScrollStart(proxy: proxy, pixelsPerSecond: pixelsPerSecond, duration: duration, viewWidth: viewWidth)
                }
                .stropheOnChange(of: pixelsPerSecond) { _ in
                    updateVisibleScrollStart(proxy: proxy, pixelsPerSecond: pixelsPerSecond, duration: duration, viewWidth: viewWidth)
                }
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
    }

    private func updateVisibleScrollStart(proxy: GeometryProxy, pixelsPerSecond: Double, duration: Double, viewWidth: CGFloat) {
        let safePPS = pixelsPerSecond.isFinite ? max(0.001, pixelsPerSecond) : 50
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        let safeViewWidth = viewWidth.isFinite ? max(1, viewWidth) : 1
        let visibleDuration = Double(safeViewWidth) / safePPS
        let maxStart = max(0, safeDuration - visibleDuration)
        let contentOffsetX = max(0, -proxy.frame(in: .named(timelineScrollCoordinateSpaceName)).minX)
        let visibleStart = min(maxStart, Double(contentOffsetX) / safePPS)

        let onePixelInSeconds = 1.0 / safePPS
        if abs(viewportStartTime - visibleStart) > onePixelInSeconds {
            viewportStartTime = visibleStart
        }
    }
    
    private func keepPlayheadInView(viewWidth: Double, duration: Double) {
        let safeViewWidth = viewWidth.isFinite ? max(1, viewWidth) : 1
        let safePPS = pixelsPerSecond.isFinite ? max(0.001, pixelsPerSecond) : 50
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        let safeCurrentTime = project.currentTime.clampedFinite(to: 0...safeDuration)
        let visibleDuration = safeViewWidth / safePPS
        let newPageStart = max(0, safeCurrentTime - visibleDuration * 0.5)
        scrollPageStartTime = max(0, min(max(0, safeDuration - visibleDuration), newPageStart))
        viewportStartTime = scrollPageStartTime
    }

    private func centerPlayheadIfNeeded(viewWidth: Double, duration: Double) {
        let safeViewWidth = viewWidth.isFinite ? max(1, viewWidth) : 1
        let safePPS = pixelsPerSecond.isFinite ? max(0.001, pixelsPerSecond) : 50
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        let safeCurrentTime = project.currentTime.clampedFinite(to: 0...safeDuration)
        let visibleDuration = safeViewWidth / safePPS
        
        let currentStart = viewportStartTime.isFinite ? viewportStartTime : 0
        let currentEnd = currentStart + visibleDuration
        
        if safeCurrentTime < currentStart || safeCurrentTime > currentEnd {
            let newPageStart = max(0, safeCurrentTime - visibleDuration * 0.5)
            scrollPageStartTime = max(0, min(max(0, safeDuration - visibleDuration), newPageStart))
            viewportStartTime = scrollPageStartTime
        }
    }
    
    /// 防抖延迟提交 Canvas 重绘：150ms 内无新缩放事件则立即将 renderedPPS 对齐 pixelsPerSecond。
    /// Canvas 用 GPU scaleEffect 展示过渡，结束后一次性重绘，分辨率完美。
    private func scheduleCanvasRedraw() {
        zoomDebounceTask?.cancel()
        zoomDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            renderedPPS = pixelsPerSecond
        }
    }
    
    /// 用内层 GeometryReader 测量到的真实内容区域宽度更新 availableWidth 和 pixelsPerSecond。
    /// 这个宽度**永远正确**（已在 NavigationSplitView 内容区域内部），不含侧栏。
    private func applyContentWidth(_ width: CGFloat, duration: Double) {
        guard width.isFinite, width > 0 else { return }
        let safeDuration = duration.isFinite ? max(1, duration) : 1
        let oldMin = availableWidth > 0 ? Double(availableWidth) / safeDuration : 0
        let wasAtMin = availableWidth <= 0 || pixelsPerSecond <= oldMin + 0.05 || pixelsPerSecond == 50.0
        
        availableWidth = width
        
        let newMin = Double(width) / safeDuration
        if wasAtMin || pixelsPerSecond < newMin {
            pixelsPerSecond = newMin
            renderedPPS = newMin
        }
    }
    
    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.path.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(String(localized: "no_media_loaded"))
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Double clamp helper
extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }

    func clampedFinite(to range: ClosedRange<Double>) -> Double {
        guard isFinite else { return range.lowerBound }
        return clamped(to: range)
    }
}

// MARK: - Cursor modifier
extension View {
    func cursor() -> some View {
        #if os(macOS)
        self.onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        #else
        self
        #endif
    }
}
