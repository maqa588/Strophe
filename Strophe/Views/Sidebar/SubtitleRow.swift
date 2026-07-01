//
//  SubtitleRow.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI

struct SubtitleRow: View, Equatable {
    let project: SubtitleProject
    let item: SubtitleItem
    let isActive: Bool
    let isOverlapping: Bool
    let group: SubGroupItem?
    let isSlapping: Bool

    static func == (lhs: SubtitleRow, rhs: SubtitleRow) -> Bool {
        lhs.item == rhs.item &&
        lhs.isActive == rhs.isActive &&
        lhs.isOverlapping == rhs.isOverlapping &&
        lhs.group == rhs.group &&
        lhs.isSlapping == rhs.isSlapping
    }

    var body: some View {
        let groupColor = group?.color ?? Color.stropheBlue

        HStack(alignment: .top, spacing: 10) {
            // Status indicator
            statusBadge
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(isActive ? .medium : .regular)
                    .foregroundStyle(isActive ? Color.stropheText : Color.stropheText.opacity(0.6))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let start = item.startTime {
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(groupColor)
                                .frame(width: 6, height: 6)
                            Text(group?.name ?? "未分组")
                                .lineLimit(1)
                        }
                        .foregroundStyle(groupColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(groupColor.opacity(0.12), in: Capsule())

                        HStack(spacing: 4) {
                            Text(formatTime(start))
                            if isSlapping {
                                Text("→")
                                TimelineView(.animation) { timeline in
                                    let smoothTime = playbackTime(at: timeline.date)
                                    Text(formatTime(smoothTime))
                                }
                            } else if let end = item.endTime {
                                Text("→")
                                Text(formatTime(end))
                            }
                        }
                        .foregroundStyle(Color.stropheBlue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.stropheBlue.opacity(0.1), in: Capsule())
                    }
                    .font(.caption2.monospaced())
                    .environment(\.layoutDirection, .leftToRight)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            isActive
                ? RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.stropheBlue.opacity(0.08))
                : nil
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isSlapping {
            Image(systemName: "record.circle")
                .font(.caption)
                .foregroundStyle(Color.stropheBlue)
        } else if isOverlapping {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
        } else if item.isTimed {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else if isActive {
            Image(systemName: "record.circle")
                .font(.caption)
                .foregroundStyle(Color.stropheBlue)
        } else {
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func playbackTime(at date: Date) -> Double {
        let rawTime = project.referenceTime + date.timeIntervalSince(project.referenceDate) * project.playbackRate
        let duration = project.activeEngine?.duration ?? 0
        let clampedTime = rawTime.isFinite ? max(0, duration > 0 ? min(duration, rawTime) : rawTime) : project.currentTime
        let start = item.startTime ?? 0
        let minDuration = project.videoFrameRate > 0 ? (1.0 / project.videoFrameRate) : 0.1
        return project.snapToFrame(max(start + minDuration, clampedTime))
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let h  = Int(seconds) / 3600
        let m  = (Int(seconds) % 3600) / 60
        let s  = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return h > 0
            ? String(format: "%d:%02d:%02d.%02d", h, m, s, ms)
            : String(format: "%02d:%02d.%02d", m, s, ms)
    }
}
