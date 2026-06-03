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
    
    // 渲染参数
    @State private var pixelsPerSecond: Double = 50
    /// 上一次 Canvas 实际绘制时使用的 PPS（缩放防抖用）
    @State private var renderedPPS: Double = 50
    @State private var playheadID = "playhead-anchor"
    @State private var isDraggingPlayhead = false
    @State private var dragStartTime: Double = 0
    @State private var isZooming = false  // 缩放节流标志
    @State private var isUserInteracting = false // 是否正在手动操作
    @State private var scrollPageStartTime: Double = 0 // 播放标尺视口分页起始时间
    @State private var viewportStartTime: Double = 0 // 当前 ScrollView 实际可见起始时间
    @State private var zoomDebounceTask: Task<Void, Never>? = nil // 缩放防抖任务
    
    // Draw Subtitle State
    @State private var drawSubtitleStartLocation: CGFloat? = nil
    @State private var drawSubtitleCurrentLocation: CGFloat? = nil
    
    // Real-time dynamic layout width state
    @State private var availableWidth: CGFloat = 800
    
    #if os(iOS)
    @State private var gestureZoomBasePPS: Double = 50.0
    #endif
    
    private var isCompact: Bool {
        return availableWidth < 540
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
                let totalWidth = CGFloat(max(1, safeDataDuration * safePPS))
                let rulerHeight: CGFloat = 25
                let waveHeight: CGFloat = 120

                GeometryReader { timelineGeo in
                    let contentWidth = timelineGeo.size.width

                    ZStack(alignment: .top) {
                        ScrollView(.horizontal, showsIndicators: true) {
                            ZStack(alignment: .topLeading) {
                                scrollOffsetReader(pixelsPerSecond: safePPS, duration: safeDataDuration, viewWidth: contentWidth)

                                WaveformTimelineContainer(
                                    project: project,
                                    data: data,
                                    viewWidth: contentWidth,
                                    totalWidth: totalWidth,
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
                                    dragStartTime: $dragStartTime
                                )
                            }
                            .padding(.bottom, 6)
                            .onChange(of: pixelsPerSecond) { _, _ in
                                keepPlayheadInView(viewWidth: Double(contentWidth), duration: data.duration)
                            }
                        }
                        // ── 宽度同步：内层 GR 永远在 NavigationSplitView 内容区域内部，
                        // 读到的 contentWidth 一定不含侧栏，这里同步给 availableWidth ──
                        .onAppear {
                            applyContentWidth(contentWidth, duration: data.duration)
                        }
                        .onChange(of: contentWidth) { _, newWidth in
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
                                    if !isZooming {
                                        isZooming = true
                                        gestureZoomBasePPS = pixelsPerSecond
                                    }
                                    let newPPS = gestureZoomBasePPS * Double(value)
                                    pixelsPerSecond = min(maxPPS, max(minPPS, newPPS))
                                }
                                .onEnded { _ in
                                    guard isZooming else { return }
                                    isZooming = false
                                    renderedPPS = pixelsPerSecond
                                    scheduleCanvasRedraw()
                                }
                        )
                        #endif
                        #if os(macOS)
                        .onContinuousHover { _ in }
                        #endif
                        .background(ScrollZoomModifier(pixelsPerSecond: $pixelsPerSecond, minPPS: minPPS, maxPPS: maxPPS, playheadTime: project.currentTime, scrollPageStartTime: $scrollPageStartTime, onCommit: scheduleCanvasRedraw))
                        
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
        .onChange(of: project.videoURL) { _, _ in
            scrollPageStartTime = 0
            viewportStartTime = 0
        }
        .onChange(of: project.waveformData?.duration) { _, duration in
            guard let duration, duration.isFinite else { return }
            // 宽度在 applyContentWidth 里已经正确，这里只重置滚动状态
            scrollPageStartTime = 0
            viewportStartTime = 0
            let safeWidth = availableWidth.isFinite ? max(1, availableWidth) : 800
            let safeDuration = max(1, duration)
            pixelsPerSecond = Double(safeWidth) / safeDuration
            renderedPPS = pixelsPerSecond
        }
        .frame(height: isCompact ? 236 : 200)
        .frame(maxWidth: .infinity)
        .background(Color.stropheSecondaryBackground)
    }

    private func scrollOffsetReader(pixelsPerSecond: Double, duration: Double, viewWidth: CGFloat) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    updateVisibleScrollStart(proxy: proxy, pixelsPerSecond: pixelsPerSecond, duration: duration, viewWidth: viewWidth)
                }
                .onChange(of: proxy.frame(in: .named(timelineScrollCoordinateSpaceName)).minX) { _, _ in
                    updateVisibleScrollStart(proxy: proxy, pixelsPerSecond: pixelsPerSecond, duration: duration, viewWidth: viewWidth)
                }
                .onChange(of: pixelsPerSecond) { _, _ in
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
        
        if wasAtMin {
            let newMin = Double(width) / safeDuration
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
            Text(String(localized: "No Media Loaded"))
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
