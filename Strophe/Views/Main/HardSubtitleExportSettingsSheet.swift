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
                Text("hard_subtitled_video_export")
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
                        Text("output_format")
                            .font(.headline)
                            .foregroundStyle(Color.stropheText)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("video_encoding")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Picker("encoding", selection: codecBinding) {
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
                                Text("output_by_aspect_ratio")
                                    .font(.subheadline)
                                Text("if_enabled_the_videos_pixel")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(CheckboxToggleStyle())
                        .tint(Color.stropheAccent)

                        Divider()
                            .background(Color.stropheBorder)

                        Toggle(isOn: hdrExportBinding) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("hdr_video_export")
                                    .font(.subheadline)
                                Text("hdr_video_export_explanation")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(CheckboxToggleStyle())
                        .tint(Color.stropheAccent)

                        if !settings.codec.isProRes && !settings.exportsHDR {
                            Divider()
                                .background(Color.stropheBorder)

                            Toggle(isOn: $settings.usesExperimentalNV12PixelBuffers) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("nv12_pixel_buffer")
                                        .font(.subheadline)
                                    Text("experimental_yuv_buffer_explanation")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(CheckboxToggleStyle())
                            .tint(Color.stropheAccent)
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
                    
                    // Section 2: Quality Card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("quality")
                            .font(.headline)
                            .foregroundStyle(Color.stropheText)
                        
                        if settings.codec.isProRes {
                            Text("prores_coding_explanation")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("control_method")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    
                                    Picker("control_method", selection: $settings.qualityMode) {
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
                                            Text("crf_constant_rate_factor")
                                                .font(.subheadline)
                                            Spacer()
                                            Text("\(Int(settings.crfLikeValue.rounded()))")
                                                .font(.body.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        Slider(value: $settings.crfLikeValue, in: 16...34, step: 1)
                                            .tint(Color.stropheAccent)
                                        Text("crf_value_explanation")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text("target_bitrate")
                                                .font(.subheadline)
                                            Spacer()
                                            Text("\(settings.targetBitrateMbps, specifier: "%.1f") Mbps")
                                                .font(.body.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        Slider(value: $settings.targetBitrateMbps, in: 0.5...80, step: 0.5)
                                            .tint(Color.stropheAccent)
                                        Text("suitable_when_needing_to_approach")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                
                                Divider()
                                    .background(Color.stropheBorder)
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("speed_size")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    
                                    Picker("speed_size", selection: $settings.speedPreset) {
                                        ForEach(HardSubtitleVideoSpeedPreset.allCases) { preset in
                                            Text(preset.title).tag(preset)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                }

                                Divider()
                                    .background(Color.stropheBorder)

                                Toggle(isOn: $settings.usesMultiPassEncoding) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("export_2pass_encoding")
                                            .font(.subheadline)
                                        Text("multipass_videotoolbox_explanation")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(CheckboxToggleStyle())
                                .tint(Color.stropheAccent)
                                
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
                
                Button("cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .tint(Color.stropheText)
                
                Button("continue") {
                    dismiss()
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stropheAccent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 480, height: 640)
        .background(VisualEffectView(material: .sheet, blendingMode: .behindWindow))
    }
    #endif

    private var iOSContent: some View {
        NavigationStack {
            Form {
                Section("output_format") {
                    Picker("video_encoding", selection: codecBinding) {
                        ForEach(HardSubtitleVideoCodec.allCases) { codec in
                            Text(codec.displayName).tag(codec)
                        }
                    }

                    Toggle("output_by_aspect_ratio", isOn: $settings.usesDisplayAspect)

                    Text("if_enabled_the_videos_pixel")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle("hdr_video_export", isOn: hdrExportBinding)

                    Text("hdr_video_export_explanation")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !settings.codec.isProRes && !settings.exportsHDR {
                        Toggle("nv12_pixel_buffer", isOn: $settings.usesExperimentalNV12PixelBuffers)

                        Text("experimental_yuv_buffer_explanation")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if settings.codec.isProRes {
                    Section("quality") {
                        Text("prores_coding_explanation")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("quality") {
                        Picker("control_method", selection: $settings.qualityMode) {
                            ForEach(HardSubtitleVideoQualityMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        if settings.qualityMode == .crfLike {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("crf")
                                    Spacer()
                                    Text("\(Int(settings.crfLikeValue.rounded()))")
                                        .font(.body.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $settings.crfLikeValue, in: 16...34, step: 1)
                                Text("crf_value_explanation")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("target_bitrate")
                                    Spacer()
                                    Text("\(settings.targetBitrateMbps, specifier: "%.1f") Mbps")
                                        .font(.body.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $settings.targetBitrateMbps, in: 0.5...80, step: 0.5)
                                Text("suitable_when_needing_to_approach")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Picker("speed_size", selection: $settings.speedPreset) {
                            ForEach(HardSubtitleVideoSpeedPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)

                        Toggle("export_2pass_encoding", isOn: $settings.usesMultiPassEncoding)

                        Text("multipass_videotoolbox_explanation")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                    }
                }
            }
            .navigationTitle("hard_subtitled_video_export")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("continue") {
                        dismiss()
                        onContinue()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var codecBinding: Binding<HardSubtitleVideoCodec> {
        Binding(
            get: { settings.codec },
            set: { codec in
                settings.codec = codec
                if !codec.supportsHDR {
                    settings.exportsHDR = false
                }
            }
        )
    }

    private var hdrExportBinding: Binding<Bool> {
        Binding(
            get: { settings.exportsHDR },
            set: { enabled in
                if enabled, !settings.codec.supportsHDR {
                    settings.codec = .h265
                }
                settings.exportsHDR = enabled
            }
        )
    }
}
