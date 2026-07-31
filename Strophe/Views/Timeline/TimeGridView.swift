//
//  TimeGridView.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI

struct TimeGridView: View {
    let pixelsPerSecond: Double
    let duration: Double
    let visibleStartTime: Double
    let viewWidth: CGFloat
    let inPoint: TimeInterval?
    let outPoint: TimeInterval?

    var body: some View {
        Canvas { context, size in
            // Choose the first interval that keeps labels comfortably separated.
            let candidateSteps: [Double] = [0.1, 0.5, 1, 2, 5, 10, 30, 60, 300, 600]
            let idealPixelSpacing: CGFloat = 80
            let step = candidateSteps.first(where: { ($0 * pixelsPerSecond) >= idealPixelSpacing }) ?? 600
            let visibleDuration = Double(max(1, viewWidth)) / max(0.001, pixelsPerSecond)
            let firstTick = max(0, floor(visibleStartTime / step) * step)
            let lastTick = min(duration, visibleStartTime + visibleDuration + step)

            for t in stride(from: firstTick, through: lastTick, by: step) {
                let x = CGFloat(t * pixelsPerSecond)

                context.fill(Path(CGRect(x: x, y: 12, width: 1, height: 8)), with: .color(.secondary))

                let timeString = formatGridTime(t, step: step)
                context.draw(
                    Text(timeString).font(.system(size: 9, design: .monospaced)), at: CGPoint(x: x + 2, y: 6),
                    anchor: .leading)

                if step >= 1 {
                    let subStep = step / 5
                    for st in stride(from: t + subStep, to: t + step, by: subStep) {
                        let sx = CGFloat(st * pixelsPerSecond)
                        context.fill(
                            Path(CGRect(x: sx, y: 15, width: 0.5, height: 5)), with: .color(.secondary.opacity(0.5)))
                    }
                }
            }

            drawRangeMarkers(in: &context, canvasSize: size)
        }
    }

    private func drawRangeMarkers(
        in context: inout GraphicsContext,
        canvasSize: CGSize
    ) {
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        let safePixelsPerSecond =
            pixelsPerSecond.isFinite ? max(0.001, pixelsPerSecond) : 50

        let validInPoint = normalizedPoint(inPoint, duration: safeDuration)
        let validOutPoint = normalizedPoint(outPoint, duration: safeDuration)

        if let start = validInPoint,
            let end = validOutPoint,
            end > start
        {
            let startX = CGFloat(start * safePixelsPerSecond)
            let endX = CGFloat(end * safePixelsPerSecond)
            context.fill(
                Path(
                    CGRect(
                        x: startX,
                        y: max(0, canvasSize.height - 4),
                        width: max(1, endX - startX),
                        height: 4
                    )
                ),
                with: .color(Color.stropheBlue.opacity(0.32))
            )
        }

        if let start = validInPoint {
            drawBoundaryMarker(
                in: &context,
                x: CGFloat(start * safePixelsPerSecond),
                label: "I",
                color: Color.stropheBlue,
                pointsRight: true,
                canvasHeight: canvasSize.height
            )
        }

        if let end = validOutPoint {
            drawBoundaryMarker(
                in: &context,
                x: CGFloat(end * safePixelsPerSecond),
                label: "O",
                color: .orange,
                pointsRight: false,
                canvasHeight: canvasSize.height
            )
        }
    }

    private func normalizedPoint(
        _ point: TimeInterval?,
        duration: Double
    ) -> TimeInterval? {
        guard let point, point.isFinite, duration > 0 else { return nil }
        return point.clamped(to: 0...duration)
    }

    private func drawBoundaryMarker(
        in context: inout GraphicsContext,
        x: CGFloat,
        label: String,
        color: Color,
        pointsRight: Bool,
        canvasHeight: CGFloat
    ) {
        let lineWidth: CGFloat = 1.5
        context.fill(
            Path(
                CGRect(
                    x: x - lineWidth / 2,
                    y: 0,
                    width: lineWidth,
                    height: canvasHeight
                )
            ),
            with: .color(color)
        )

        let flagWidth: CGFloat = 13
        let flagHeight: CGFloat = 11
        let flagX = pointsRight ? x : x - flagWidth
        let flagRect = CGRect(
            x: flagX,
            y: 0,
            width: flagWidth,
            height: flagHeight
        )
        context.fill(
            Path(roundedRect: flagRect, cornerRadius: 2),
            with: .color(color)
        )
        context.draw(
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundColor(.white),
            at: CGPoint(x: flagRect.midX, y: flagRect.midY),
            anchor: .center
        )
    }

    private func formatGridTime(_ t: Double, step: Double) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        if step < 0.5 {
            let ms = Int((t.truncatingRemainder(dividingBy: 1)) * 10)
            return String(format: "%02d:%02d.%d", m, s, ms)
        } else if step < 1 {
            // For 0.5 step, showing ms is optional but helpful to differentiate
            let ms = Int((t.truncatingRemainder(dividingBy: 1)) * 10)
            return ms == 0 ? String(format: "%02d:%02d", m, s) : String(format: "%02d:%02d.%d", m, s, ms)
        } else if t >= 3600 {
            let h = Int(t) / 3600
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}
