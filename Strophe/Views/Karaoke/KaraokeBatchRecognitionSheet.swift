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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("karaoke_batch_intro")
                        .foregroundStyle(.secondary)

                    if showsAlignmentOptions {
                        alignmentOptions
                    } else {
                        modeCard(
                            title: "karaoke_batch_align_existing",
                            detail: "karaoke_batch_align_existing_detail",
                            icon: "waveform.badge.magnifyingglass"
                        ) {
                            showsAlignmentOptions = true
                        }
                        modeCard(
                            title: "karaoke_batch_import_advanced",
                            detail: "karaoke_batch_import_advanced_detail",
                            icon: "square.and.arrow.down"
                        ) {
                            isImporting = true
                        }
                    }
                }
                .padding(22)
            }
            .navigationTitle("karaoke_batch_recognition")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("btn_cancel") { dismiss() }
                        .disabled(isRunning)
                }
            }
        }
        .frame(minWidth: 540, minHeight: 430)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: UTType.allSubtitleTypes,
            allowsMultipleSelection: false
        ) { result in
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
        .alert(resultTitle, isPresented: $isShowingResultAlert) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(resultMessage)
        }
    }

    private var alignmentOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                showsAlignmentOptions = false
            } label: {
                Label("back", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)

            Picker("karaoke_batch_alignment_method", selection: $method) {
                Text("karaoke_batch_local_aligner").tag(CaptionGenerationMode.local)
                Text("karaoke_batch_cloud_aligner").tag(CaptionGenerationMode.cloud)
            }
            .pickerStyle(.segmented)

            Picker("submission_language", selection: $language) {
                Text("auto_detect").tag("auto")
                Text("recognition_language_simplified_chinese").tag("zh")
                Text("recognition_language_english").tag("en")
                Text("recognition_language_japanese").tag("ja")
                Text("recognition_language_korean").tag("ko")
            }

            Label(
                String(format: String(localized: "karaoke_batch_timed_cues_format"), timedItems.count),
                systemImage: "captions.bubble"
            )

            if isRunning {
                ProgressView(value: progress)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            if let resultSucceeded {
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
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (resultSucceeded ? Color.green : Color.red)
                        .opacity(0.1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }

            Button {
                startAlignment()
            } label: {
                Label("karaoke_batch_start", systemImage: "music.note.list")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning || timedItems.isEmpty || project.videoURL == nil)
        }
        .padding()
        .background(Color.stropheSecondaryBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func modeCard(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 42, height: 42)
                    .background(Color.stropheAccent.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.stropheSecondaryBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.stropheBorder))
    }

    private func startAlignment() {
        guard let mediaURL = project.videoURL else { return }
        let cues = timedItems
        isRunning = true
        progress = 0
        status = String(localized: "karaoke_batch_preparing")
        resultSucceeded = nil
        resultMessage = ""

        Task {
            do {
                let wordsByCueID: [UUID: [SubtitleWordTiming]]
                switch method {
                case .cloud:
                    let baseURL = try AIBackendClient.normalizedCloudBaseURL(from: cloudBaseURLString)
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
                        language: language,
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
                        cues: cues
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
                await MainActor.run {
                    project.applyBatchKaraokePrograms(programs)
                    progress = 1
                    status = String(format: String(localized: "karaoke_batch_complete_format"), programs.count)
                    isRunning = false
                    let methodName = method == .local
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
                        title: String(localized: skipped == 0 && fallbackCount == 0
                            ? "karaoke_batch_succeeded"
                            : "karaoke_batch_partially_succeeded"),
                        message: message
                    )
                }
            } catch {
                await MainActor.run {
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
        cues: [SubtitleItem]
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
