import SwiftUI
import UniformTypeIdentifiers

struct CurrentMediaInfoView: View {
    @ObservedObject var project: SubtitleProject

    @State private var snapshot: MediaInformationSnapshot?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var reloadID = UUID()
    @State private var activeRequest: ProbeRequest?
    @State private var extractionStream: MediaStreamInformation?
    @State private var isShowingStreamExporter = false
    @State private var isExtractingStream = false
    @State private var extractionError: String?

    private var mediaURL: URL? {
        if project.mediaAccessStatus.canRead,
           let resolvedURL = project.mediaAccessStatus.resolvedURL {
            return resolvedURL
        }
        guard let videoURL = project.videoURL else { return nil }

        // `videoURL` is commonly a temporary symlink. Prefer the original
        // security-scoped URL only when it resolves to this exact media file.
        let resolvedVideoURL = videoURL.resolvingSymlinksInPath()
        if let accessURL = project.mediaAccessURL,
           accessURL.resolvingSymlinksInPath() == resolvedVideoURL {
            return accessURL
        }
        return videoURL
    }

    private var probeRequest: ProbeRequest {
        ProbeRequest(
            url: mediaURL,
            accessState: project.mediaAccessStatus.state,
            reloadID: reloadID
        )
    }

    var body: some View {
        Group {
            if let accessErrorMessage {
                errorState(accessErrorMessage)
            } else if mediaURL == nil {
                emptyState
            } else if let snapshot {
                mediaDetails(snapshot)
            } else if let errorMessage {
                errorState(errorMessage)
            } else {
                // Always render a concrete view before the first probe begins.
                // A conditional Group with no matching branch becomes EmptyView,
                // and lifecycle modifiers on it may never start.
                loadingState
            }
        }
        .background(Color.stropheBackground)
        .inlineNavigationTitle(String(localized: "current_media_info"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    reloadID = UUID()
                } label: {
                    Label("media_info_refresh", systemImage: "arrow.clockwise")
                }
                .disabled(mediaURL == nil || isLoading)
            }
        }
        .task(id: probeRequest) {
            await loadMediaInformation(for: probeRequest)
        }
        .fileExporter(
            isPresented: $isShowingStreamExporter,
            document: BinaryDeliveryDocument(data: Data()),
            contentType: extractionContentType,
            defaultFilename: extractionDefaultFileName
        ) { result in
            guard case .success(let destinationURL) = result,
                  let stream = extractionStream,
                  let mediaURL else {
                extractionStream = nil
                return
            }
            isExtractingStream = true
            Task { @MainActor in
                defer {
                    isExtractingStream = false
                    extractionStream = nil
                }
                do {
                    try await MediaStreamExtractionService.extract(
                        stream: stream,
                        from: mediaURL,
                        to: destinationURL
                    )
                } catch {
                    extractionError = error.localizedDescription
                }
            }
        }
        .overlay {
            if isExtractingStream {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    ProgressView(String(localized: "media_extract_in_progress"))
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .alert(
            String(localized: "media_extract_failed"),
            isPresented: Binding(
                get: { extractionError != nil },
                set: { if !$0 { extractionError = nil } }
            )
        ) {
            Button(String(localized: "ok"), role: .cancel) {
                extractionError = nil
            }
        } message: {
            Text(extractionError ?? "")
        }
    }

    private var accessErrorMessage: String? {
        let status = project.mediaAccessStatus
        switch status.state {
        case .missing:
            return status.technicalMessage ?? String(localized: "media_access_missing")
        case .permissionDenied:
            return status.technicalMessage ?? String(localized: "media_access_permission_denied")
        case .unreadable:
            return status.technicalMessage ?? String(localized: "media_access_unreadable")
        case .unsupported:
            return status.technicalMessage ?? String(localized: "media_access_unsupported")
        case .none, .resolving, .ready:
            return nil
        }
    }

    private var emptyState: some View {
        MediaInfoStateView(
            icon: "film.stack",
            title: String(localized: "media_info_no_media"),
            message: String(localized: "media_info_no_media_description")
        )
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("media_info_loading")
                .font(.headline)
                .foregroundStyle(Color.stropheText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        MediaInfoStateView(
            icon: "exclamationmark.triangle",
            title: String(localized: "media_info_unavailable"),
            message: message,
            actionTitle: String(localized: "media_info_retry")
        ) {
            reloadID = UUID()
        }
    }

    private func mediaDetails(_ snapshot: MediaInformationSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                MediaInfoHero(snapshot: snapshot, isRefreshing: isLoading)

                MediaInfoCard(
                    title: String(localized: "media_info_basic"),
                    subtitle: snapshot.formatSummary,
                    icon: "doc.fill",
                    fields: snapshot.fileFields
                )

                ForEach(snapshot.streams) { stream in
                    MediaInfoCard(
                        title: streamTitle(stream),
                        subtitle: stream.codecName,
                        icon: stream.kind.iconName,
                        fields: stream.fields,
                        actionTitle: stream.extractionFileExtension == nil
                            ? nil
                            : String(localized: "media_extract_stream")
                    ) {
                        extractionStream = stream
                        isShowingStreamExporter = true
                    }
                }
            }
            .frame(maxWidth: 840)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .textSelection(.enabled)
        .refreshable {
            reloadID = UUID()
        }
    }

    private var extractionContentType: UTType {
        guard let pathExtension = extractionStream?.extractionFileExtension else {
            return .data
        }
        return UTType(filenameExtension: pathExtension) ?? .data
    }

    private var extractionDefaultFileName: String {
        extractionStream?.extractionSuggestedFileName ?? "stream.bin"
    }

    private func streamTitle(_ stream: MediaStreamInformation) -> String {
        let kind = String(localized: String.LocalizationValue(stream.kind.localizedNameKey))
        return String.localizedStringWithFormat(
            String(localized: "media_info_stream_title_format"),
            stream.id,
            kind
        )
    }

    @MainActor
    private func loadMediaInformation(for request: ProbeRequest) async {
        activeRequest = request

        guard let mediaURL = request.url else {
            snapshot = nil
            errorMessage = nil
            isLoading = false
            activeRequest = nil
            return
        }

        isLoading = true
        errorMessage = nil
        if snapshot?.sourceURL != mediaURL.resolvingSymlinksInPath() {
            snapshot = nil
        }
        defer {
            if activeRequest == request {
                isLoading = false
                activeRequest = nil
            }
        }

        do {
            let loaded = try await MediaInformationProbe.load(from: mediaURL)
            guard !Task.isCancelled, activeRequest == request else { return }
            snapshot = loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, activeRequest == request else { return }
            snapshot = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct ProbeRequest: Equatable, Sendable {
    let url: URL?
    let accessState: MediaAccessState
    let reloadID: UUID
}

private struct MediaInfoHero: View {
    let snapshot: MediaInformationSnapshot
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: snapshot.videoStreamCount > 0 ? "film.stack.fill" : "waveform")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.stropheAccent)
                .frame(width: 56, height: 56)
                .background(Color.stropheAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(snapshot.displayName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)

                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                HStack(spacing: 8) {
                    if snapshot.videoStreamCount > 0 {
                        MediaInfoChip(
                            text: "\(snapshot.videoStreamCount) \(String(localized: "media_stream_video"))",
                            icon: "film"
                        )
                    }
                    if snapshot.audioStreamCount > 0 {
                        MediaInfoChip(
                            text: "\(snapshot.audioStreamCount) \(String(localized: "media_stream_audio"))",
                            icon: "waveform"
                        )
                    }
                    if let duration = snapshot.duration {
                        MediaInfoChip(text: compactDuration(duration), icon: "clock")
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(Color.stropheSecondaryBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.stropheBorder.opacity(0.45), lineWidth: 1)
        )
    }

    private func compactDuration(_ duration: Double) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds / 60) % 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

private struct MediaInfoChip: View {
    let text: String
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.stropheBackground.opacity(0.72), in: Capsule())
    }
}

private struct MediaInfoCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let fields: [MediaInformationField]
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(Color.stropheAccent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.stropheText)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .background(Color.stropheAccent.opacity(0.08))

            ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                if index > 0 {
                    Divider()
                        .padding(.leading, 16)
                }
                MediaInfoFieldRow(field: field)
            }
        }
        .background(Color.stropheSecondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.stropheBorder.opacity(0.45), lineWidth: 1)
        )
    }
}

private struct MediaInfoFieldRow: View {
    let field: MediaInformationField

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                fieldLabel
                    .frame(width: 170, alignment: .leading)
                fieldValue
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel
                fieldValue
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var fieldLabel: some View {
        Text(String(localized: String.LocalizationValue(field.labelKey)))
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var fieldValue: some View {
        Text(field.value)
            .font(.system(.subheadline, design: .monospaced))
            .foregroundStyle(Color.stropheText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MediaInfoStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(Color.stropheAccent)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.stropheText)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
