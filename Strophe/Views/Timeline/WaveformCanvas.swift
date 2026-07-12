//
//  WaveformCanvas.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI

struct WaveformCanvas: View {
    @ObservedObject var data: WaveformData
    let pixelsPerSecond: Double
    
    // 根据 pixelsPerSecond 选择最合适的 mipmap 层（超采样优先，保证极致清晰度）
    private var optimalLevel: (zoom: Int, bins: [WaveformBin])? {
        guard !data.levels.isEmpty else { return nil }
        let sampleRate = data.sampleRate
        let optimal = sampleRate / pixelsPerSecond
        let bestKey = WaveformProcessor.zoomLevels.last { Double($0) <= optimal }
            ?? WaveformProcessor.zoomLevels[0]
        guard let bins = data.levels[bestKey] else { return nil }
        return (bestKey, bins)
    }
    
    var body: some View {
        if let level = optimalLevel, !level.bins.isEmpty {
            let bins = level.bins
            let chunkDuration = 30.0  // 每个渲染分片时长为 30 秒，即使放大也绝不超过 6000 像素，完美避开 16k 硬件限制
            let totalChunks = Int(ceil(data.duration / chunkDuration))
            
            // A lazy horizontal stack is not stable for this use case: each
            // Canvas can be thousands of points wide and the whole stack is
            // temporarily scaled during zoom. SwiftUI may evict a still-visible
            // leading chunk using the pre-scale layout bounds, leaving a blank
            // time range. Keep the lightweight Canvas nodes eagerly laid out.
            HStack(spacing: 0) {
                ForEach(0..<totalChunks, id: \.self) { index in
                    let startTime = Double(index) * chunkDuration
                    let endTime = min(data.duration, Double(index + 1) * chunkDuration)
                    let duration = endTime - startTime
                    
                    // Derive bin positions from absolute sample time. Using a
                    // duration ratio lets floor rounding vary when switching
                    // mip levels and can accumulate a visible horizontal drift.
                    let startIndex = min(
                        bins.count,
                        max(0, Int(startTime * data.sampleRate) / level.zoom)
                    )
                    let endIndex = min(
                        bins.count,
                        max(startIndex, Int(endTime * data.sampleRate) / level.zoom)
                    )
                    let chunkWidth = CGFloat(duration * pixelsPerSecond)
                    
                    WaveformChunkCanvas(bins: bins, range: startIndex..<endIndex)
                        .frame(width: chunkWidth)
                }
            }
        }
    }
}

/// 对应 30秒 单一分段的高性能矢量 Canvas 绘制器
struct WaveformChunkCanvas: View {
    let bins: [WaveformBin]
    let range: Range<Int>
    
    var body: some View {
        Canvas { context, size in
            guard !bins.isEmpty, !range.isEmpty else { return }
            
            let midY = size.height / 2
            let totalBins = range.count
            let binWidth = size.width / CGFloat(totalBins)
            
            // 创建单一路径以整合所有峰值和 RMS 数据，实现零渲染开销
            var peakPath = Path()
            var rmsPath = Path()
            
            for (offset, index) in range.enumerated() {
                let bin = bins[index]
                let x = CGFloat(offset) * binWidth
                
                // 1. 物理峰值包络线 (Peak Envelope)
                let peakTop = midY - CGFloat(bin.peakPositive) * midY
                let peakBottom = midY - CGFloat(bin.peakNegative) * midY
                peakPath.move(to: CGPoint(x: x, y: peakTop))
                peakPath.addLine(to: CGPoint(x: x, y: peakBottom))
                
                // 2. 能量有效值包络线 (RMS Core)
                let rmsHeight = CGFloat(bin.rms) * midY * 1.5
                rmsPath.move(to: CGPoint(x: x, y: midY - rmsHeight))
                rmsPath.addLine(to: CGPoint(x: x, y: midY + rmsHeight))
            }
            
            // 笔触宽度稍微窄于 binWidth 能够产生精美的像素间隔线，防止连在一片
            let drawWidth = max(1.0, binWidth * 0.75)
            
            // 绘制精细的 Peak 外轮廓
            context.stroke(
                peakPath,
                with: .color(.stropheWaveformPeak),
                lineWidth: drawWidth
            )
            
            // 绘制 RMS 能量内核
            context.stroke(
                rmsPath,
                with: .color(.stropheWaveformRMS),
                lineWidth: drawWidth
            )
        }
    }
}
