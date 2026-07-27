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
                        
                        Toggle(isOn: $settings.usesSoftwareEncoding) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("software_encoding")
                                    .font(.subheadline)
                                Text("software_encoding_explanation")
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

                            Toggle(isOn: $settings.usesBGRACompatibilityPixelBuffers) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("bgra_compatibility_mode")
                                        .font(.subheadline)
                                    Text("bgra_compatibility_mode_explanation")
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
                                    
                                    Picker("control_method", selection: $settings.rateControlMode) {
                                        ForEach(HardSubtitleVideoRateControlMode.allCases) { mode in
                                            Text(mode.title).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                }
                                
                                if settings.rateControlMode == .constantQuality {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text("constant_quality")
                                                .font(.subheadline)
                                            Spacer()
                                            Text("\(Int(settings.constantQualityPercent.rounded()))")
                                                .font(.body.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        Slider(value: $settings.constantQualityPercent, in: 0...100, step: 1)
                                            .tint(Color.stropheAccent)
                                        Text("constant_quality_explanation")
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

                    Toggle("software_encoding", isOn: $settings.usesSoftwareEncoding)

                    Text("software_encoding_explanation")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle("hdr_video_export", isOn: hdrExportBinding)

                    Text("hdr_video_export_explanation")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !settings.codec.isProRes && !settings.exportsHDR {
                        Toggle("bgra_compatibility_mode", isOn: $settings.usesBGRACompatibilityPixelBuffers)

                        Text("bgra_compatibility_mode_explanation")
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
                        Picker("control_method", selection: $settings.rateControlMode) {
                            ForEach(HardSubtitleVideoRateControlMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        if settings.rateControlMode == .constantQuality {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("constant_quality_short")
                                    Spacer()
                                    Text("\(Int(settings.constantQualityPercent.rounded()))")
                                        .font(.body.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $settings.constantQualityPercent, in: 0...100, step: 1)
                                Text("constant_quality_explanation")
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
