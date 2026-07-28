import SwiftUI

struct HardSubtitleExportSettingsSheet: View {
    @Binding var settings: HardSubtitleVideoExportSettings
    let mediaURL: URL?
    let onContinue: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var audioTrackOptions: [AudioTrackExportOption] = []
    @State private var isLoadingAudioTracks = false
    @State private var audioTrackLoadFailed = false

    var body: some View {
        Group {
            #if os(macOS)
            macOSContent
            #else
            iOSContent
            #endif
        }
        .task(id: mediaURL) {
            await loadAudioTrackOptions()
        }
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

                    VStack(alignment: .leading, spacing: 12) {
                        Text("video_delivery_options")
                            .font(.headline)
                            .foregroundStyle(Color.stropheText)

                        macOSDeliveryOptions
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
        .frame(width: 500, height: 720)
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

                    Toggle(isOn: $settings.usesSoftwareEncoding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("software_encoding")
                                .font(.subheadline)
                            Text("software_encoding_explanation")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: hdrExportBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("hdr_video_export")
                                .font(.subheadline)
                            Text("hdr_video_export_explanation")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !settings.codec.isProRes && !settings.exportsHDR {
                        Toggle(isOn: $settings.usesBGRACompatibilityPixelBuffers) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("bgra_compatibility_mode")
                                    .font(.subheadline)
                                Text("bgra_compatibility_mode_explanation")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
                                        .font(.subheadline)
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
                                        .font(.subheadline)
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

                        Toggle(isOn: $settings.usesMultiPassEncoding) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("export_2pass_encoding")
                                    .font(.subheadline)
                                Text("multipass_videotoolbox_explanation")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("video_delivery_options") {
                    iOSDeliveryOptions
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
                if !codec.supportsAlpha {
                    settings.exportsTransparentBackground = false
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
                if enabled {
                    settings.exportsTransparentBackground = false
                }
            }
        )
    }

    private var macOSDeliveryOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: transparentBackgroundBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("transparent_alpha_mov")
                        .font(.subheadline)
                    Text("transparent_alpha_mov_explanation")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(CheckboxToggleStyle())
            .tint(Color.stropheAccent)

            Divider()
                .background(Color.stropheBorder)

            Toggle(isOn: $settings.usesProjectRange) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("export_in_out_range")
                        .font(.subheadline)
                    Text(
                        hasProjectRange
                            ? rangeSummary
                            : String(localized: "export_in_out_range_unavailable")
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            .disabled(!hasProjectRange)
            .toggleStyle(CheckboxToggleStyle())
            .tint(Color.stropheAccent)

            Divider()
                .background(Color.stropheBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("watermark_text")
                    .font(.subheadline)
                TextField(
                    String(localized: "watermark_text"),
                    text: $settings.watermarkText
                )
                .textFieldStyle(.roundedBorder)
            }

            Divider()
                .background(Color.stropheBorder)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $settings.burnsTimecode) {
                    Text("burn_timecode")
                        .font(.subheadline)
                }
                .toggleStyle(CheckboxToggleStyle())
                .tint(Color.stropheAccent)

                if settings.burnsTimecode {
                    Toggle(isOn: $settings.timecodeStartsAtZero) {
                        Text("timecode_starts_at_export_range")
                            .font(.subheadline)
                    }
                    .toggleStyle(CheckboxToggleStyle())
                    .tint(Color.stropheAccent)
                    .padding(.leading, 16)
                }
            }

            Divider()
                .background(Color.stropheBorder)

            audioTracksSection
        }
    }

    private var iOSDeliveryOptions: some View {
        Group {
            Toggle(isOn: transparentBackgroundBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("transparent_alpha_mov")
                        .font(.subheadline)
                    Text("transparent_alpha_mov_explanation")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $settings.usesProjectRange) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("export_in_out_range")
                        .font(.subheadline)
                    Text(
                        hasProjectRange
                            ? rangeSummary
                            : String(localized: "export_in_out_range_unavailable")
                    )
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            .disabled(!hasProjectRange)

            VStack(alignment: .leading, spacing: 4) {
                Text("watermark_text")
                    .font(.subheadline)
                TextField(
                    String(localized: "watermark_text"),
                    text: $settings.watermarkText
                )
            }

            Toggle(isOn: $settings.burnsTimecode) {
                Text("burn_timecode")
                    .font(.subheadline)
            }

            if settings.burnsTimecode {
                Toggle(isOn: $settings.timecodeStartsAtZero) {
                    Text("timecode_starts_at_export_range")
                        .font(.subheadline)
                }
                .padding(.leading, 12)
            }

            audioTracksSection
        }
    }

    private var audioTracksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("audio_tracks")
                    .font(.subheadline.weight(.medium))

                Spacer()

                if !audioTrackOptions.isEmpty {
                    Button("audio_tracks_all") {
                        settings.includedAudioTrackOrdinals = nil
                    }
                    .buttonStyle(.borderless)

                    Button("audio_tracks_none") {
                        settings.includedAudioTrackOrdinals = []
                    }
                    .buttonStyle(.borderless)
                }
            }

            if isLoadingAudioTracks {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("audio_tracks_loading")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if audioTrackLoadFailed {
                Text("audio_tracks_unavailable")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if audioTrackOptions.isEmpty {
                Text("audio_tracks_empty")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(audioTrackOptions) { option in
                    Toggle(
                        option.label,
                        isOn: audioTrackBinding(for: option.ordinal)
                    )
                    #if os(macOS)
                    .toggleStyle(CheckboxToggleStyle())
                    .tint(Color.stropheAccent)
                    #endif
                }
            }

            Text("audio_tracks_explanation")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var transparentBackgroundBinding: Binding<Bool> {
        Binding(
            get: { settings.rendersTransparentBackground },
            set: { enabled in
                if enabled {
                    settings.codec = .proRes4444
                    settings.exportsHDR = false
                }
                settings.exportsTransparentBackground = enabled
            }
        )
    }

    private var hasProjectRange: Bool {
        guard let start = settings.rangeStartSeconds,
              let end = settings.rangeEndSeconds else {
            return false
        }
        return start.isFinite && end.isFinite && end > start
    }

    private var rangeSummary: String {
        guard let start = settings.rangeStartSeconds,
              let end = settings.rangeEndSeconds else {
            return ""
        }
        return "\(exportTime(start)) – \(exportTime(end))"
    }

    private func exportTime(_ seconds: Double) -> String {
        let milliseconds = Int((max(0, seconds) * 1_000).rounded())
        return String(
            format: "%02d:%02d:%02d.%03d",
            milliseconds / 3_600_000,
            (milliseconds / 60_000) % 60,
            (milliseconds / 1_000) % 60,
            milliseconds % 1_000
        )
    }

    @MainActor
    private func loadAudioTrackOptions() async {
        audioTrackOptions = []
        audioTrackLoadFailed = false
        guard let mediaURL else { return }

        isLoadingAudioTracks = true
        defer { isLoadingAudioTracks = false }

        do {
            let snapshot = try await MediaInformationProbe.load(from: mediaURL)
            guard !Task.isCancelled else { return }
            audioTrackOptions = snapshot.streams
                .filter { $0.kind == .audio }
                .enumerated()
                .map { ordinal, stream in
                    let language = stream.fields.first {
                        $0.id.localizedCaseInsensitiveContains("language")
                    }?.value
                    let details = [stream.codecName, language]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    return AudioTrackExportOption(
                        ordinal: ordinal,
                        label: "\(ordinal + 1) · #\(stream.id) · \(details)"
                    )
                }
        } catch {
            guard !Task.isCancelled else { return }
            audioTrackLoadFailed = true
        }
    }

    private func audioTrackBinding(for ordinal: Int) -> Binding<Bool> {
        Binding(
            get: {
                settings.includesAudioTrack(ordinal: ordinal)
            },
            set: { isIncluded in
                var selection = settings.includedAudioTrackOrdinals
                    ?? Set(audioTrackOptions.map(\.ordinal))
                if isIncluded {
                    selection.insert(ordinal)
                } else {
                    selection.remove(ordinal)
                }
                settings.includedAudioTrackOrdinals = selection
            }
        )
    }
}

private struct AudioTrackExportOption: Identifiable {
    let ordinal: Int
    let label: String

    var id: Int { ordinal }
}
