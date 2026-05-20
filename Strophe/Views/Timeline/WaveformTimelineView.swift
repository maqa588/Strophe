//
//  WaveformTimelineView.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/16.
//

import SwiftUI

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
        let viewWidth = availableWidth
        let duration = project.waveformData?.duration ?? 1
        let minPPS = viewWidth / max(1, duration)
        let maxPPS = viewWidth / 5.0

        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.stropheTimelineDivider)
                .frame(height: 1)
            
            // MARK: - Extracted Timeline Toolbar
            TimelineToolbarView(project: project)
                .fixedSize(horizontal: false, vertical: true)

            // MARK: - Timeline Core
            if let data = project.waveformData {
                let totalWidth = CGFloat(data.duration * pixelsPerSecond)
                let rulerHeight: CGFloat = 25
                let waveHeight: CGFloat = 120

                ZStack(alignment: .top) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        ScrollViewReader { proxy in
                            // 🚀 硬件级刷新率同步渲染引擎 - 自适应当前显示器的 100Hz/120Hz 物理高刷新率！
                            TimelineView(.animation) { timeline in
                                WaveformTimelineContainer(
                                    project: project,
                                    timeline: timeline,
                                    data: data,
                                    viewWidth: viewWidth,
                                    totalWidth: totalWidth,
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
                                    proxy: proxy
                                )
                            }
                            .padding(.bottom, 6)
                            .onChange(of: project.currentTime) { _, newTime in
                                handleTimeChange(newTime, viewWidth: Double(viewWidth), duration: data.duration, proxy: proxy)
                            }
                            .onChange(of: pixelsPerSecond) { _, _ in
                                keepPlayheadInView(viewWidth: Double(viewWidth), duration: data.duration, proxy: proxy)
                            }
                        }
                    }
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
                                isZooming = false
                                renderedPPS = pixelsPerSecond
                                scheduleCanvasRedraw()
                            }
                    )
                    #endif
                    #if os(macOS)
                    .onContinuousHover { _ in }
                    #endif
                    .background(ScrollZoomModifier(pixelsPerSecond: $pixelsPerSecond, minPPS: minPPS, maxPPS: maxPPS, onCommit: scheduleCanvasRedraw))
                    
                    #if os(iOS)
                    if project.editingMode == .creation {
                        SlapButtonsOverlay(project: project)
                    }
                    #endif
                }
                .frame(height: rulerHeight + waveHeight + 6)

            } else {
                emptyPlaceholder
            }
        }
        .padding(.bottom, 12)
        .environment(\.layoutDirection, .leftToRight)
        .onAppear {
            if let data = project.waveformData {
                let pps = viewWidth / max(1, data.duration)
                pixelsPerSecond = pps
                renderedPPS = pps
            } else {
                pixelsPerSecond = minPPS
                renderedPPS = minPPS
            }
            scrollPageStartTime = 0
        }
        .onChange(of: project.videoURL) { _, _ in
            scrollPageStartTime = 0
        }
        .onChange(of: project.waveformData?.duration) { _, duration in
            if let duration = duration {
                let newMinPPS = availableWidth / max(1, duration)
                pixelsPerSecond = newMinPPS
                renderedPPS = newMinPPS
                scrollPageStartTime = 0
            }
        }
        .frame(height: isCompact ? 236 : 200)
        .frame(maxWidth: .infinity)
        .background(Color.stropheSecondaryBackground)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        availableWidth = geo.size.width
                    }
                    .onChange(of: geo.size.width) { oldWidth, newWidth in
                        availableWidth = newWidth
                    }
            }
        )
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
    
    private func handleTimeChange(_ newTime: Double, viewWidth: Double, duration: Double, proxy: ScrollViewProxy) {
        let visibleDuration = viewWidth / pixelsPerSecond
        if isDraggingPlayhead {
            let pad = visibleDuration * 0.1
            if newTime < scrollPageStartTime + pad {
                scrollPageStartTime = max(0, newTime - pad)
                proxy.scrollTo("scroll-page-anchor", anchor: .leading)
            } else if newTime > scrollPageStartTime + visibleDuration - pad {
                let targetPageStart = newTime - visibleDuration + pad
                scrollPageStartTime = max(0, min(max(0, duration - visibleDuration), targetPageStart))
                proxy.scrollTo("scroll-page-anchor", anchor: .leading)
            }
            return
        }
        
        guard !isUserInteracting else { return }
        
        // Logic Pro style: Instant page flip when playhead hits either boundary
        if newTime >= scrollPageStartTime + visibleDuration || newTime < scrollPageStartTime {
            let pageIndex = Int(newTime / max(0.001, visibleDuration))
            let targetPageStart = Double(pageIndex) * visibleDuration
            let clampedPageStart = max(0, min(max(0, duration - visibleDuration), targetPageStart))
            
            scrollPageStartTime = clampedPageStart
            proxy.scrollTo("scroll-page-anchor", anchor: .leading)
        }
    }
    
    private func keepPlayheadInView(viewWidth: Double, duration: Double, proxy: ScrollViewProxy) {
        let visibleDuration = viewWidth / pixelsPerSecond
        let newPageStart = max(0, project.currentTime - visibleDuration * 0.5)
        scrollPageStartTime = max(0, min(max(0, duration - visibleDuration), newPageStart))
        proxy.scrollTo("scroll-page-anchor", anchor: .leading)
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
