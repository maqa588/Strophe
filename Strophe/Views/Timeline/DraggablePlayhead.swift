//
//  DraggablePlayhead.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI

struct DraggablePlayhead: View {
    @Binding var currentTime: Double
    @Binding var isScrubbing: Bool
    @Binding var isDragging: Bool
    @Binding var dragStartTime: Double
    let pixelsPerSecond: Double
    let duration: Double
    let project: SubtitleProject

    // 磁力吸附与防抖状态
    @State private var isSnapped = false
    @State private var snappedTime: Double? = nil

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

    var body: some View {
        ZStack(alignment: .top) {
            // Vertical line
            Rectangle()
                .fill(Color.stropheAccent)
                .frame(width: 2.0)

            // Triangular head (Logic Pro style)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.stropheAccent)
                .offset(y: -12)
        }
        .frame(width: 2.0)
        .offset(x: -1.0) // 居中补偿：向左平移半个线宽以精准对齐时间点
        // Make the hit area wide enough to grab easily
        .contentShape(Rectangle().inset(by: -12))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging {
                        // Drag start: snapshot the current time
                        isDragging = true
                        isScrubbing = true
                        dragStartTime = currentTime
                    }
                    
                    let delta = Double(value.translation.width) / pixelsPerSecond
                    let rawProposedTime = (dragStartTime + delta).clamped(to: 0...duration)
                    
                    // TimelineIndex performs a binary search instead of rebuilding
                    // and scanning an edge array on every pointer event.
                    let closestSnap = project.timelineIndex.nearestSnapPoint(to: rawProposedTime)
                    let minDistance = closestSnap.map { abs($0 - rawProposedTime) } ?? .infinity
                    
                    // 10 像素磁吸，20 像素挣脱防抖阈值
                    let activeThreshold = isSnapped ? (20.0 / pixelsPerSecond) : (10.0 / pixelsPerSecond)
                    
                    var finalTime = rawProposedTime
                    if minDistance <= activeThreshold, let snap = closestSnap {
                        if !isSnapped {
                            isSnapped = true
                            snappedTime = snap
                            triggerHapticFeedback()
                        }
                        finalTime = snap
                    } else {
                        isSnapped = false
                        snappedTime = nil
                    }
                    
                    currentTime = finalTime
                }
                .onEnded { _ in
                    isDragging = false
                    isScrubbing = false
                    isSnapped = false
                    snappedTime = nil
                    // Sync the reference time so the timeline doesn't jump back when paused
                    project.referenceTime = currentTime
                    project.referenceDate = .now
                }
        )
        .cursor() // 显示左右拉伸光标
    }
}
