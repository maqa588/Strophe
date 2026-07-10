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
    
    var body: some View {
        Canvas { context, size in
            // 动态计算步长：寻找让刻度间距保持在 60-150px 之间的最佳时间间隔
            let candidateSteps: [Double] = [0.1, 0.5, 1, 2, 5, 10, 30, 60, 300, 600]
            let idealPixelSpacing: CGFloat = 80
            let step = candidateSteps.first(where: { ($0 * pixelsPerSecond) >= idealPixelSpacing }) ?? 600
            let visibleDuration = Double(max(1, viewWidth)) / max(0.001, pixelsPerSecond)
            let firstTick = max(0, floor(visibleStartTime / step) * step)
            let lastTick = min(duration, visibleStartTime + visibleDuration + step)
            
            for t in stride(from: firstTick, through: lastTick, by: step) {
                let x = CGFloat(t * pixelsPerSecond)
                
                // 大刻度
                context.fill(Path(CGRect(x: x, y: 12, width: 1, height: 8)), with: .color(.secondary))
                
                // 绘制时间文本
                let timeString = formatGridTime(t, step: step)
                context.draw(Text(timeString).font(.system(size: 9, design: .monospaced)), at: CGPoint(x: x + 2, y: 6), anchor: .leading)
                
                // 中间小刻度 (仅在步长较大时绘制)
                if step >= 1 {
                    let subStep = step / 5
                    for st in stride(from: t + subStep, to: t + step, by: subStep) {
                        let sx = CGFloat(st * pixelsPerSecond)
                        context.fill(Path(CGRect(x: sx, y: 15, width: 0.5, height: 5)), with: .color(.secondary.opacity(0.5)))
                    }
                }
            }
        }
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
