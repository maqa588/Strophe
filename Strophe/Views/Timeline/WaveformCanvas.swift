//
//  WaveformCanvas.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI

struct WaveformCanvas: View {
    let data: WaveformData
    let pixelsPerSecond: Double
    
    // 根据 pixelsPerSecond 选择最合适的 mipmap 层（超采样优先，保证极致清晰度）
    private var optimalBins: [WaveformBin]? {
        guard !data.levels.isEmpty else { return nil }
        let sampleRate = 44100.0
        let optimal = sampleRate / pixelsPerSecond
        let sortedKeys = data.levels.keys.sorted()  // [220, 880, 4410]
        
        let bestKey = sortedKeys.last { Double($0) <= optimal } ?? sortedKeys.first!
        return data.levels[bestKey]
    }
    
    var body: some View {
        if let bins = optimalBins, !bins.isEmpty {
            let chunkDuration = 30.0  // 每个渲染分片时长为 30 秒，即使放大也绝不超过 6000 像素，完美避开 16k 硬件限制
            let totalChunks = Int(ceil(data.duration / chunkDuration))
            
            HStack(spacing: 0) {
                ForEach(0..<totalChunks, id: \.self) { index in
                    let startTime = Double(index) * chunkDuration
                    let endTime = min(data.duration, Double(index + 1) * chunkDuration)
                    let duration = endTime - startTime
                    
                    // 精准截取属于当前分段的 Bins
                    let startIndex = Int((startTime / data.duration) * Double(bins.count))
                    let endIndex = min(bins.count, Int((endTime / data.duration) * Double(bins.count)))
                    let chunkBins = Array(bins[startIndex..<endIndex])
                    
                    let chunkWidth = CGFloat(duration * pixelsPerSecond)
                    
                    WaveformChunkCanvas(bins: chunkBins)
                        .frame(width: chunkWidth)
                }
            }
        }
    }
}

/// 对应 30秒 单一分段的高性能矢量 Canvas 绘制器
struct WaveformChunkCanvas: View {
    let bins: [WaveformBin]
    
    var body: some View {
        Canvas { context, size in
            guard !bins.isEmpty else { return }
            
            let midY = size.height / 2
            let totalBins = bins.count
            let binWidth = size.width / CGFloat(totalBins)
            
            // 创建单一路径以整合所有峰值和 RMS 数据，实现零渲染开销
            var peakPath = Path()
            var rmsPath = Path()
            
            for i in 0..<totalBins {
                let bin = bins[i]
                let x = CGFloat(i) * binWidth
                
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
