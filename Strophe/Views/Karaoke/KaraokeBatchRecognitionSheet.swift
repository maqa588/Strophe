import SwiftUI
import UniformTypeIdentifiers

struct KaraokeBatchRecognitionSheet: View {
    @ObservedObject var project: SubtitleProject
    @Environment(\.dismiss) private var dismiss
    @StateObject private var modelManager = LocalModelManager.shared
    @AppStorage(AIBackendClient.cloudBaseURLDefaultsKey)
    private var cloudBaseURLString = AIBackendClient.defaultCloudBaseURL.absoluteString

    @State private var showsAlignmentOptions = false
    @State private var method: CaptionGenerationMode = .local
    @State private var language = "auto"
    @State private var isImporting = false
    @State private var isRunning = false
    @State private var progress = 0.0
    @State private var status = ""
    @State private var resultSucceeded: Bool?
    @State private var resultTitle = ""
    @State private var resultMessage = ""
    @State private var isShowingResultAlert = false

    private var timedItems: [SubtitleItem] {
        project.items.filter(\.isTimed)
    }

    var body: some View {
        platformContent
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: UTType.allSubtitleTypes,
                allowsMultipleSelection: false
            ) { result in handleImportResult(result) }
            .alert(resultTitle, isPresented: $isShowingResultAlert) {
                Button("ok", role: .cancel) {}
            } message: {
                Text(resultMessage)
            }
    }

    @ViewBuilder
    private var platformContent: some View {
        #if os(macOS)
        mainContent
            .frame(width: 480, height: 600)
            .background(
                VisualEffectView(
                    material: .sheet,
                    blendingMode: .behindWindow
                )
            )
        #else
        mobileContent
        #endif
    }

    #if !os(macOS)
    @ViewBuilder
    private var mobileContent: some View {
        NavigationView {
            Form {
                if isRunning {
                    mobileRunningSection
                } else if showsAlignmentOptions {
                    mobileMediaSection
                    mobileAlignmentMethodSection
                    mobileLanguageSection
                    if method == .cloud {
                        mobileServerSection
                    }
                    if resultSucceeded != nil {
                        mobileResultSection
                    }
                } else {
                    mobileMediaSection
                    mobileRecognitionModeSection
                }
            }
            .navigationTitle("karaoke_batch_recognition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if showsAlignmentOptions && !isRunning {
                        Button("back") {
                            showsAlignmentOptions = false
                        }
                    } else {
                        Button("btn_cancel") {
                            dismiss()
                        }
                        .disabled(isRunning)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    if isRunning {
                        ProgressView()
                    } else if showsAlignmentOptions {
                        Button("karaoke_batch_start", action: startAlignment)
                            .fontWeight(.bold)
                            .disabled(!canStartAlignment)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var mobileMediaSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: project.videoURL == nil
                    ? "exclamationmark.triangle.fill"
                    : "music.note.list")
                    .font(.title2)
                    .foregroundStyle(project.videoURL == nil
                        ? Color.orange
                        : Color.stropheAccent)

                VStack(alignment: .leading, spacing: 4) {
                    Text(project.documentName.isEmpty
                        ? String(localized: "untitled_project")
                        : project.documentName)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Text(String(
                        format: String(localized: "karaoke_batch_timed_cues_format"),
                        timedItems.count
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("karaoke_batch_intro")
        }
    }

    @ViewBuilder
    private var mobileRecognitionModeSection: some View {
        Section {
            Button {
                showsAlignmentOptions = true
            } label: {
                mobileRecognitionRow(
                    title: "karaoke_batch_align_existing",
                    systemImage: "waveform.badge.magnifyingglass",
                    status: alignmentAvailabilityStatus,
                    detail: "karaoke_batch_align_existing_detail",
                    isAvailable: canStartAlignment
                )
            }
            .buttonStyle(.plain)
            .disabled(!canStartAlignment)

            Button {
                isImporting = true
            } label: {
                mobileRecognitionRow(
                    title: "karaoke_batch_import_advanced",
                    systemImage: "square.and.arrow.down",
                    status: "available",
                    detail: "karaoke_batch_import_advanced_detail",
                    isAvailable: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func mobileRecognitionRow(
        title: LocalizedStringKey,
        systemImage: String,
        status: LocalizedStringKey,
        detail: LocalizedStringKey,
        isAvailable: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(isAvailable
                        ? Color.stropheText
                        : Color.secondary)

                Spacer()

                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isAvailable
                        ? Color.stropheAccent
                        : Color.secondary)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var mobileAlignmentMethodSection: some View {
        Section {
            Picker("karaoke_batch_alignment_method", selection: $method) {
                Text("karaoke_batch_local_aligner")
                    .tag(CaptionGenerationMode.local)
                Text("karaoke_batch_cloud_aligner")
                    .tag(CaptionGenerationMode.cloud)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            Text("karaoke_batch_alignment_method")
        }
    }

    @ViewBuilder
    private var mobileLanguageSection: some View {
        Section {
            Picker("submission_language", selection: $language) {
                Text("auto_detect").tag("auto")
                Text("recognition_language_simplified_chinese").tag("zh")
                Text("recognition_language_traditional_chinese").tag("zh-TW")
                Text("recognition_language_english").tag("en")
                Text("recognition_language_japanese").tag("ja")
                Text("recognition_language_korean").tag("ko")
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("submission_language")
        }
    }

    @ViewBuilder
    private var mobileServerSection: some View {
        Section {
            TextField(
                AIBackendClient.defaultCloudBaseURL.absoluteString,
                text: $cloudBaseURLString
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
            Text("server_address")
        }
    }

    @ViewBuilder
    private var mobileRunningSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)

                HStack {
                    Text(status.isEmpty
                        ? String(localized: "karaoke_batch_preparing")
                        : status)
                        .font(.subheadline)

                    Spacer()

                    Text(String(format: "%.0f%%", progress * 100))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var mobileResultSection: some View {
        if let resultSucceeded {
            Section {
                Label {
                    Text(resultMessage)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: resultSucceeded
                        ? "checkmark.circle.fill"
                        : "xmark.octagon.fill")
                }
                .foregroundStyle(resultSucceeded ? .green : .red)
            }
        }
    }
    #endif

    private var canStartAlignment: Bool {
        !timedItems.isEmpty && project.videoURL != nil && !isRunning
    }

    private var alignmentAvailabilityStatus: LocalizedStringKey {
        if project.videoURL == nil {
            return "media_required"
        }
        if timedItems.isEmpty {
            return "no_script"
        }
        return "recommended"
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("karaoke_batch_recognition")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.stropheText)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(isRunning)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()
                .background(Color.stropheBorder)

            // Body Content
            if isRunning {
                runningStateView
            } else if showsAlignmentOptions {
                ScrollView {
                    alignmentOptions
                        .padding(24)
                }
            } else {
                ScrollView {
                    recognitionModeGuide
                        .padding(24)
                }
            }

            Divider()
                .background(Color.stropheBorder)

            // Bottom Actions
            HStack {
                if showsAlignmentOptions && !isRunning {
                    Button("back") {
                        showsAlignmentOptions = false
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.stropheText)
                }

                Spacer()

                Button("btn_cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(isRunning)
                .tint(Color.stropheText)

                if showsAlignmentOptions {
                    Button(action: startAlignment) {
                        Text("karaoke_batch_start")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.stropheAccent)
                    .disabled(!canStartAlignment)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private var recognitionModeGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Media status card
            HStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.stropheAccent)
                    .frame(width: 36, height: 36)
                    .background(Color.stropheAccent.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.documentName.isEmpty ? String(localized: "untitled_project") : project.documentName)
                        .font(.headline)
                        .foregroundStyle(Color.stropheText)
                        .lineLimit(1)
                    Text(String(format: String(localized: "karaoke_batch_timed_cues_format"), timedItems.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(Color.stropheSecondaryBackground.opacity(0.6))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.stropheBorder, lineWidth: 1))

            Text("karaoke_batch_intro")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Choice 1: Align existing subtitles
            Button {
                showsAlignmentOptions = true
            } label: {
                recognitionChoiceCard(
                    title: "karaoke_batch_align_existing",
                    systemImage: "waveform.badge.magnifyingglass",
                    status: String(localized: "recommended"),
                    detail: "karaoke_batch_align_existing_detail",
                    isProminent: true,
                    isAvailable: !timedItems.isEmpty && project.videoURL != nil
                )
            }
            .buttonStyle(.plain)
            .disabled(timedItems.isEmpty || project.videoURL == nil)

            // Choice 2: Import advanced ASS Karaoke
            Button {
                isImporting = true
            } label: {
                recognitionChoiceCard(
                    title: "karaoke_batch_import_advanced",
                    systemImage: "square.and.arrow.down",
                    status: String(localized: "available"),
                    detail: "karaoke_batch_import_advanced_detail",
                    isProminent: false,
                    isAvailable: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func recognitionChoiceCard(
        title: String,
        systemImage: String,
        status: String,
        detail: String,
        isProminent: Bool,
        isAvailable: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isProminent && isAvailable ? Color.stropheAccent : .secondary)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(LocalizedStringKey(title))
                        .font(.headline)
                        .foregroundStyle(Color.stropheText)

                    Spacer()

                    Text(status)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(isAvailable ? Color.stropheAccent : .secondary)
                }

                Text(LocalizedStringKey(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.stropheSecondaryBackground.opacity(isProminent ? 0.7 : 0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isProminent && isAvailable ? Color.stropheAccent.opacity(0.55) : Color.stropheBorder, lineWidth: 1)
        )
        .opacity(isAvailable ? 1.0 : 0.62)
    }

    @ViewBuilder
    private var alignmentOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("karaoke_batch_alignment_method")
                    .font(.headline)
                    .foregroundStyle(Color.stropheText)

                Picker("karaoke_batch_alignment_method", selection: $method) {
                    Text("karaoke_batch_local_aligner").tag(CaptionGenerationMode.local)
                    Text("karaoke_batch_cloud_aligner").tag(CaptionGenerationMode.cloud)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(14)
            .background(Color.stropheSecondaryBackground.opacity(0.5))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.stropheBorder, lineWidth: 1))

            VStack(alignment: .leading, spacing: 10) {
                Text("submission_language")
                    .font(.headline)
                    .foregroundStyle(Color.stropheText)

                Picker("submission_language", selection: $language) {
                    Text("auto_detect").tag("auto")
                    Text("recognition_language_simplified_chinese").tag("zh")
                    Text("recognition_language_traditional_chinese").tag("zh-TW")
                    Text("recognition_language_english").tag("en")
                    Text("recognition_language_japanese").tag("ja")
                    Text("recognition_language_korean").tag("ko")
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .padding(14)
            .background(Color.stropheSecondaryBackground.opacity(0.5))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.stropheBorder, lineWidth: 1))

            if method == .cloud {
                VStack(alignment: .leading, spacing: 10) {
                    Text("server_address")
                        .font(.headline)
                        .foregroundStyle(Color.stropheText)

                    TextField(
                        AIBackendClient.defaultCloudBaseURL.absoluteString,
                        text: $cloudBaseURLString
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                }
                .padding(14)
                .background(Color.stropheSecondaryBackground.opacity(0.5))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.stropheBorder, lineWidth: 1))
            }

            if let resultSucceeded {
                Label {
                    Text(resultMessage)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: resultSucceeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                }
                .foregroundStyle(resultSucceeded ? .green : .red)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((resultSucceeded ? Color.green : Color.red).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder
    private var runningStateView: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView(value: progress) {
                Text(status.isEmpty ? String(localized: "karaoke_batch_preparing") : status)
                    .font(.headline)
                    .foregroundStyle(Color.stropheText)
            }
            .progressViewStyle(.linear)
            .padding(.horizontal, 40)

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(String(format: "%.0f%%", progress * 100))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startAlignment() {
        guard let mediaURL = project.videoURL else { return }
        let cues = timedItems
        let selectedMethod = method
        let selectedLanguage = language
        let selectedCloudBaseURL = cloudBaseURLString
        isRunning = true
        progress = 0
        status = String(localized: "karaoke_batch_preparing")
        resultSucceeded = nil
        resultMessage = ""

        Task { @MainActor in
            do {
                let wordsByCueID: [UUID: [SubtitleWordTiming]]
                switch selectedMethod {
                case .cloud:
                    let baseURL = try AIBackendClient.normalizedCloudBaseURL(
                        from: selectedCloudBaseURL
                    )
                    let alignment = try await AIBackendClient.shared.alignCloudSubtitles(
                        mediaURL: mediaURL,
                        endpointURL: AIBackendClient.cloudAlignURL(baseURL: baseURL),
                        cues: cues.compactMap { cue in
                            guard let start = cue.startTime, let end = cue.endTime else { return nil }
                            return AICloudAlignmentCue(
                                id: cue.id,
                                text: cue.text,
                                startTime: start,
                                endTime: end
                            )
                        },
                        language: selectedLanguage,
                        progressCallback: { value, message in
                            Task { @MainActor in
                                progress = min(0.85, value * 0.85)
                                status = message
                            }
                        }
                    )
                    wordsByCueID = alignment.wordsByCueID
                case .local:
                    wordsByCueID = try await localAlignedWords(
                        mediaURL: mediaURL,
                        cues: cues,
                        language: selectedLanguage
                    )
                }

                var programs: [UUID: KaraokeProgram] = [:]
                var fallbackCount = 0
                for cue in cues {
                    guard let start = cue.startTime, let end = cue.endTime else { continue }
                    let cueWords = wordsByCueID[cue.id] ?? []
                    if let program = KaraokeProgram.fromAlignedWords(
                        cueWords,
                        cueText: cue.text,
                        cueStartTime: start,
                        cueEndTime: end,
                        isEnabled: true
                    ) {
                        programs[cue.id] = program
                    } else if let fallback = KaraokeProgram.evenlyTimed(
                        text: cue.text,
                        duration: max(0, end - start),
                        template: .classicSweep
                    ) {
                        // Existing transcript text is authoritative. A single
                        // local/CoreML failure must not invalidate the entire
                        // batch or leave a partially highlighted cue.
                        programs[cue.id] = fallback
                        fallbackCount += 1
                    }
                }
                guard !programs.isEmpty else {
                    throw NSError(domain: "KaraokeBatch", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: String(localized: "karaoke_batch_no_timing_generated")
                    ])
                }
                project.applyBatchKaraokePrograms(programs)
                progress = 1
                status = String(
                    format: String(localized: "karaoke_batch_complete_format"),
                    programs.count
                )
                isRunning = false
                let methodName = selectedMethod == .local
                    ? String(localized: "karaoke_batch_local_aligner")
                    : String(localized: "karaoke_batch_cloud_aligner")
                let skipped = max(0, cues.count - programs.count)
                let message = String(
                    format: String(
                        localized: "karaoke_batch_result_with_fallback_format"
                    ),
                    methodName,
                    programs.count,
                    cues.count,
                    fallbackCount,
                    skipped
                )
                presentResult(
                    succeeded: true,
                    title: String(
                        localized: skipped == 0 && fallbackCount == 0
                            ? "karaoke_batch_succeeded"
                            : "karaoke_batch_partially_succeeded"
                    ),
                    message: message
                )
            } catch {
                isRunning = false
                status = String(localized: "karaoke_batch_failed")
                presentResult(
                    succeeded: false,
                    title: String(localized: "karaoke_batch_failed"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        Task { @MainActor in
            do {
                guard let url = try result.get().first else { return }
                try project.importSubtitle(from: url)
                dismiss()
            } catch {
                presentResult(
                    succeeded: false,
                    title: String(localized: "karaoke_batch_failed"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func presentResult(
        succeeded: Bool,
        title: String,
        message: String
    ) {
        resultSucceeded = succeeded
        resultTitle = title
        resultMessage = message
        isShowingResultAlert = true
    }

    private func localAlignedWords(
        mediaURL: URL,
        cues: [SubtitleItem],
        language: String
    ) async throws -> [UUID: [SubtitleWordTiming]] {
        #if STROPHE_LOCAL_AI
        guard #available(macOS 15.0, iOS 18.0, *) else {
            throw NSError(domain: "KaraokeBatch", code: 3, userInfo: [
                NSLocalizedDescriptionKey: AIBackendClient.unsupportedDeviceMessage
            ])
        }
        let alignmentLanguage = language
        let modelStorageRoot = modelManager.resolvedExternalURL()
        let hasModelStorageAccess = modelStorageRoot?.startAccessingSecurityScopedResource() ?? false
        #if os(macOS)
        if modelStorageRoot != nil && !hasModelStorageAccess {
            throw NSError(domain: "KaraokeBatch", code: 4, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "karaoke_batch_storage_permission")
            ])
        }
        #endif
        defer {
            if hasModelStorageAccess {
                modelStorageRoot?.stopAccessingSecurityScopedResource()
            }
        }
        guard let modelURL = modelManager.getModelDirectory(
            for: LocalModelManager.forcedAlignerINT8ModelName,
            type: .aligner
        ) else {
            throw NSError(domain: "KaraokeBatch", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "karaoke_batch_aligner_missing")
            ])
        }
        return try await Task.detached {
            let samples = try await AudioExtractor.extract(from: mediaURL, targetSampleRate: 16_000)
            let aligner = try CoreMLQwen3ForcedAligner(directory: modelURL)
            var result: [UUID: [SubtitleWordTiming]] = [:]
            for cue in cues {
                guard let start = cue.startTime, let end = cue.endTime, end > start else { continue }
                // Small acoustic context prevents clipped consonants at subtitle
                // edges from collapsing the first/last timestamp slot.
                let contextStart = max(0, start - 0.25)
                let contextEnd = min(
                    Double(samples.count) / 16_000,
                    end + 0.25
                )
                let lower = min(
                    samples.count,
                    max(0, Int(contextStart * 16_000))
                )
                let upper = min(
                    samples.count,
                    max(lower, Int(contextEnd * 16_000))
                )
                guard upper > lower, upper - lower <= 30 * 16_000 else {
                    result[cue.id] = []
                    continue
                }
                do {
                    let aligned = try aligner.align(
                        audio: Array(samples[lower..<upper]),
                        text: cue.text,
                        language: alignmentLanguage
                    )
                    result[cue.id] = aligned.map {
                        SubtitleWordTiming(
                            text: $0.text,
                            startTime: contextStart + $0.start,
                            endTime: contextStart + $0.end
                        )
                    }
                } catch {
                    // Isolate inference instability to this cue. The caller
                    // supplies deterministic even timing for an empty result.
                    print(
                        "⚠️ ForcedAligner cue fallback \(cue.id): "
                            + error.localizedDescription
                    )
                    result[cue.id] = []
                }
            }
            return result
        }.value
        #else
        throw NSError(domain: "KaraokeBatch", code: 2, userInfo: [
            NSLocalizedDescriptionKey: AIBackendClient.unsupportedDeviceMessage
        ])
        #endif
    }
}
