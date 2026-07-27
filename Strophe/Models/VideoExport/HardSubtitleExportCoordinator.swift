import Combine
import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// Owns a hard-subtitle export independently of the presenting sheet and, on
/// supported iOS/iPadOS versions, hands its lifetime to the system.
@MainActor
final class HardSubtitleExportCoordinator: ObservableObject {
    @Published private(set) var progress: Double?
    @Published private(set) var completionMessage: String?

    private var exportTask: Task<Void, Never>?
    private var lastDisplayedPercent = -1

    func start(
        project: SubtitleProject,
        settings: HardSubtitleVideoExportSettings,
        destinationURL: URL
    ) {
        guard exportTask == nil, progress == nil else { return }

        progress = 0
        completionMessage = nil
        lastDisplayedPercent = -1

        #if os(iOS)
        if #available(iOS 26.0, *),
           submitContinuedProcessingTask(
               project: project,
               settings: settings,
               destinationURL: destinationURL
           ) {
            return
        }
        #endif

        beginExport(
            project: project,
            settings: settings,
            destinationURL: destinationURL
        )
    }

    func clearCompletionMessage() {
        completionMessage = nil
    }

    private func beginExport(
        project: SubtitleProject,
        settings: HardSubtitleVideoExportSettings,
        destinationURL: URL
    ) {
        runExport(
            project: project,
            settings: settings,
            destinationURL: destinationURL
        )
    }

    #if os(iOS)
    @available(iOS 26.0, *)
    private func submitContinuedProcessingTask(
        project: SubtitleProject,
        settings: HardSubtitleVideoExportSettings,
        destinationURL: URL
    ) -> Bool {
        guard BGTaskScheduler.supportedResources.contains(.gpu) else {
            return false
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "top.maqa.Strophe"
        let identifier = "\(bundleIdentifier).hardSubtitleExport.\(UUID().uuidString)"
        let scheduler = BGTaskScheduler.shared
        let didRegister = scheduler.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { [weak self] task in
            MainActor.assumeIsolated {
                guard let continuedTask = task as? BGContinuedProcessingTask,
                      let self else {
                    task.setTaskCompleted(success: false)
                    return
                }

                self.beginExport(
                    project: project,
                    settings: settings,
                    destinationURL: destinationURL,
                    continuedTask: continuedTask
                )
            }
        }
        guard didRegister else {
            return false
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: String(localized: "hard_subtitle_export"),
            subtitle: String(localized: "exporting_hard_subtitled_video")
        )
        request.strategy = .fail
        request.requiredResources = .gpu

        do {
            try scheduler.submit(request)
            return true
        } catch {
            // The export is user initiated, so start it in the foreground rather
            // than leaving the UI waiting for a queued background request.
            print("Background hard-subtitle export unavailable: \(error.localizedDescription)")
            return false
        }
    }

    @available(iOS 26.0, *)
    private func beginExport(
        project: SubtitleProject,
        settings: HardSubtitleVideoExportSettings,
        destinationURL: URL,
        continuedTask: BGContinuedProcessingTask
    ) {
        runExport(
            project: project,
            settings: settings,
            destinationURL: destinationURL,
            continuedTask: continuedTask
        )
    }
    #endif

    private func runExport(
        project: SubtitleProject,
        settings: HardSubtitleVideoExportSettings,
        destinationURL: URL
    ) {
        guard exportTask == nil else { return }
        let didAccessDestination = destinationURL.startAccessingSecurityScopedResource()

        exportTask = Task { [self] in
            defer {
                if didAccessDestination {
                    destinationURL.stopAccessingSecurityScopedResource()
                }
                progress = nil
                exportTask = nil
            }

            do {
                try await HardSubtitleVideoExporter.export(
                    project: project,
                    settings: settings,
                    destinationURL: destinationURL
                ) { [weak self] value in
                    self?.progress = value
                }
                completionMessage = String(
                    localized: "export_completed_format \(destinationURL.lastPathComponent)"
                )
            } catch {
                completionMessage = error.localizedDescription
            }
        }
    }

    #if os(iOS)
    @available(iOS 26.0, *)
    private func runExport(
        project: SubtitleProject,
        settings: HardSubtitleVideoExportSettings,
        destinationURL: URL,
        continuedTask: BGContinuedProcessingTask
    ) {
        guard exportTask == nil else {
            continuedTask.setTaskCompleted(success: false)
            return
        }

        let didAccessDestination = destinationURL.startAccessingSecurityScopedResource()
        continuedTask.progress.totalUnitCount = 1_000
        continuedTask.progress.completedUnitCount = 0
        continuedTask.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.exportTask?.cancel()
            }
        }

        exportTask = Task { [self] in
            var didSucceed = false
            defer {
                if didAccessDestination {
                    destinationURL.stopAccessingSecurityScopedResource()
                }
                continuedTask.expirationHandler = nil
                continuedTask.setTaskCompleted(success: didSucceed)
                progress = nil
                exportTask = nil
            }

            do {
                try await HardSubtitleVideoExporter.export(
                    project: project,
                    settings: settings,
                    destinationURL: destinationURL
                ) { [weak self] value in
                    self?.report(value, to: continuedTask)
                }
                report(1, to: continuedTask)
                didSucceed = true
                completionMessage = String(
                    localized: "export_completed_format \(destinationURL.lastPathComponent)"
                )
            } catch {
                completionMessage = error.localizedDescription
            }
        }
    }

    @available(iOS 26.0, *)
    private func report(_ rawValue: Double, to task: BGContinuedProcessingTask) {
        let value = min(max(rawValue, 0), 1)
        progress = value
        task.progress.completedUnitCount = Int64((value * 1_000).rounded())

        let percent = Int((value * 100).rounded())
        guard percent != lastDisplayedPercent else { return }
        lastDisplayedPercent = percent
        task.updateTitle(
            String(localized: "hard_subtitle_export"),
            subtitle: "\(percent)%"
        )
    }
    #endif
}
