import SwiftUI

struct HardSubtitleExportSettingsSheet: View {
    @Binding var settings: HardSubtitleVideoExportSettings
    let onContinue: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        macOSContent
        #else
        iOSContent
        #endif
    }

    #if os(macOS)
    private var macOSContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("硬字幕视频导出")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.stropheText)
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)
            
            Divider()
                .background(Color.stropheBorder)
            
            ScrollView {
                VStack(spacing: 20) {
                    // Section 1: Output Format Card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("输出格式")
                            .font(.headline)
                            .foregroundStyle(Color.stropheText)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("视频编码")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Picker("编码", selection: $settings.codec) {
                                ForEach(HardSubtitleVideoCodec.allCases) { codec in
                                    Text(codec.displayName).tag(codec)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        
                        Divider()
                            .background(Color.stropheBorder)
                        
                        Toggle(isOn: $settings.usesDisplayAspect) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("按显示比例输出")
                                    .font(.subheadline)
                                Text("开启后会读取视频的像素宽高比和 clean aperture。比如存储为 1920×1080、显示为 4:3 的视频，会按 1440×1080 这类真实显示尺寸重新合成，避免画面被挤歪。")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(CheckboxToggleStyle())
                        .tint(Color.stropheAccent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.stropheSecondaryBackground.opacity(0.5))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.stropheBorder, lineWidth: 1)
                    )
                    
                    // Section 2: Quality Card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("质量")
                            .font(.headline)
                            .foregroundStyle(Color.stropheText)
                        
                        if settings.codec == .proRes422 {
                            Text("ProRes 422 使用 Apple 固定的中间片编码参数，适合继续剪辑或高质量归档；码率由 ProRes 规格和画面尺寸决定。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("控制方式")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    
                                    Picker("控制方式", selection: $settings.qualityMode) {
                                        ForEach(HardSubtitleVideoQualityMode.allCases) { mode in
                                            Text(mode.title).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                }
                                
                                if settings.qualityMode == .crfLike {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text("CRF (画质系数)")
                                                .font(.subheadline)
                                            Spacer()
                                            Text("\(Int(settings.crfLikeValue.rounded()))")
                                                .font(.body.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        Slider(value: $settings.crfLikeValue, in: 16...34, step: 1)
                                            .tint(Color.stropheAccent)
                                        Text("数字越小画质越高、文件越大。Apple VideoToolbox 不开放 x264/x265 的真 CRF，这里会用类 CRF 估算码率。")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text("目标码率")
                                                .font(.subheadline)
                                            Spacer()
                                            Text("\(settings.targetBitrateMbps, specifier: "%.1f") Mbps")
                                                .font(.body.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        Slider(value: $settings.targetBitrateMbps, in: 0.5...80, step: 0.5)
                                            .tint(Color.stropheAccent)
                                        Text("适合需要接近参考软件码率或控制最终文件大小时使用。")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                
                                Divider()
                                    .background(Color.stropheBorder)
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("速度 / 体积")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    
                                    Picker("速度 / 体积", selection: $settings.speedPreset) {
                                        ForEach(HardSubtitleVideoSpeedPreset.allCases) { preset in
                                            Text(preset.title).tag(preset)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                }
                                
                                Text("1080p 30fps 预估：\(estimatedBitrateText)。实际码率仍由 VideoToolbox 和画面复杂度决定。")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.stropheSecondaryBackground.opacity(0.5))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.stropheBorder, lineWidth: 1)
                    )
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            
            Divider()
                .background(Color.stropheBorder)
            
            // Bottom Actions
            HStack {
                Spacer()
                
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .tint(Color.stropheText)
                
                Button("继续") {
                    dismiss()
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stropheAccent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 480, height: 520)
        .background(VisualEffectView(material: .sheet, blendingMode: .behindWindow))
    }
    #endif

    private var iOSContent: some View {
        NavigationStack {
            Form {
                Section("输出格式") {
                    Picker("视频编码", selection: $settings.codec) {
                        ForEach(HardSubtitleVideoCodec.allCases) { codec in
                            Text(codec.displayName).tag(codec)
                        }
                    }

                    Toggle("按显示比例输出", isOn: $settings.usesDisplayAspect)

                    Text("开启后会读取视频的像素宽高比和 clean aperture。比如存储为 1920×1080、显示为 4:3 的视频，会按 1440×1080 这类真实显示尺寸重新合成，避免画面被挤歪。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if settings.codec == .proRes422 {
                    Section("质量") {
                        Text("ProRes 422 使用 Apple 固定的中间片编码参数，适合继续剪辑或高质量归档；码率由 ProRes 规格和画面尺寸决定。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("质量") {
                        Picker("控制方式", selection: $settings.qualityMode) {
                            ForEach(HardSubtitleVideoQualityMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        if settings.qualityMode == .crfLike {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("CRF")
                                    Spacer()
                                    Text("\(Int(settings.crfLikeValue.rounded()))")
                                        .font(.body.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $settings.crfLikeValue, in: 16...34, step: 1)
                                Text("数字越小画质越高、文件越大。Apple VideoToolbox 不开放 x264/x265 的真 CRF，这里会用类 CRF 估算码率。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("目标码率")
                                    Spacer()
                                    Text("\(settings.targetBitrateMbps, specifier: "%.1f") Mbps")
                                        .font(.body.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $settings.targetBitrateMbps, in: 0.5...80, step: 0.5)
                                Text("适合需要接近参考软件码率或控制最终文件大小时使用。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Picker("速度 / 体积", selection: $settings.speedPreset) {
                            ForEach(HardSubtitleVideoSpeedPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text("1080p 30fps 预估：\(estimatedBitrateText)。实际码率仍由 VideoToolbox 和画面复杂度决定。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("硬字幕视频导出")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("继续") {
                        dismiss()
                        onContinue()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }


    private var estimatedBitrateText: String {
        guard settings.codec != .proRes422 else { return "ProRes 自动" }
        let bitrate = settings.resolvedBitrate(width: 1920, height: 1080, frameRate: 30)
        return String(format: "%.2f Mbps", Double(bitrate) / 1_000_000)
    }
}
