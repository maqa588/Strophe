//
//  SubtitleRow.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI

struct SubtitleRow: View {
    let item: SubtitleItem
    let index: Int
    let isActive: Bool
    let isOverlapping: Bool

    var body: some View {
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
                    HStack(spacing: 4) {
                        Text(formatTime(start))
                        if let end = item.endTime {
                            Text("→")
                            Text(formatTime(end))
                        }
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.stropheBlue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.stropheBlue.opacity(0.1), in: Capsule())
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
        if isOverlapping {
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
                .symbolEffect(.pulse, isActive: isActive)
        } else {
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
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
