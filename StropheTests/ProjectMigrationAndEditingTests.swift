import XCTest
@testable import Strophe

final class ProjectMigrationAndEditingTests: XCTestCase {
    func testDeliveryTypesAreDeclaredInApplicationInfoPlist() throws {
        let declarations = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations")
                as? [[String: Any]]
        )
        let identifiers = Set(
            declarations.compactMap { $0["UTTypeIdentifier"] as? String }
        )

        XCTAssertTrue(
            identifiers.contains("org.openxmlformats.spreadsheetml.sheet")
        )
        XCTAssertTrue(
            identifiers.contains("com.apple.final-cut-pro.xml")
        )
    }

    @MainActor
    func testSelectedReadableMediaIsPreparedBeforePublishingPlaybackURL() async throws {
        let mediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Readable-\(UUID().uuidString).mp4")
        try Data([0x00, 0x00, 0x00, 0x18]).write(to: mediaURL)
        defer { try? FileManager.default.removeItem(at: mediaURL) }
        let project = SubtitleProject()

        await project.replaceMedia(with: mediaURL)

        XCTAssertNotNil(project.videoURL)
        XCTAssertEqual(project.mediaAccessStatus.state, .ready)
        XCTAssertNil(project.mediaLoadError)
        project.createNewProject()
    }

    @MainActor
    func testMissingSelectedMediaReportsFailureWithoutPublishingPlaybackURL() async {
        let missingMediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingSelection-\(UUID().uuidString).mp4")
        let project = SubtitleProject()

        await project.replaceMedia(with: missingMediaURL)

        XCTAssertNil(project.videoURL)
        XCTAssertEqual(project.mediaAccessStatus.state, .missing)
        XCTAssertEqual(project.mediaLoadError, missingMediaURL.lastPathComponent)
    }

    @MainActor
    func testMissingCrossDeviceMediaStaysOutOfPlaybackPipeline() async throws {
        let missingMediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Missing-\(UUID().uuidString).mp4")
        let blank = StropheProjectData.blank()
        let projectData = StropheProjectData(
            version: blank.version,
            metadata: blank.metadata,
            media: .init(originalURL: missingMediaURL, bookmark: nil),
            tracks: blank.tracks,
            styles: blank.styles,
            subgroupStyles: blank.subgroupStyles,
            subtitleGroups: blank.subtitleGroups,
            interchangeDocuments: blank.interchangeDocuments,
            timeline: blank.timeline
        )
        let project = SubtitleProject()

        try await project.loadStropheData(projectData, from: nil)

        XCTAssertNil(project.videoURL)
        XCTAssertEqual(project.mediaAccessStatus.state, .missing)
        XCTAssertEqual(project.mediaLoadError, missingMediaURL.lastPathComponent)

        let detection = await FormatDetector.shared.detect(url: missingMediaURL)
        XCTAssertFalse(detection.isSourceAccessible)
        XCTAssertEqual(detection.sourceAccessFailure, .missing)
    }

    func testAppleMediaContainersPreferAVFoundation() {
        XCTAssertTrue(
            FormatDetector.prefersAVFoundation(
                for: URL(fileURLWithPath: "/Media/native.MP4")
            )
        )
        XCTAssertTrue(
            FormatDetector.prefersAVFoundation(
                for: URL(fileURLWithPath: "/Media/native.mov")
            )
        )
        XCTAssertFalse(
            FormatDetector.prefersAVFoundation(
                for: URL(fileURLWithPath: "/Media/fallback.mkv")
            )
        )
    }

    func testFFmpegLoadSessionReportsOpenFailure() async {
        let missingMediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Missing-\(UUID().uuidString).mp4")
        let core = FFmpegDecoderCore()

        let didLoad = await core.loadSession(url: missingMediaURL)

        XCTAssertFalse(didLoad)
    }

    @MainActor
    func testVersionOneProjectMigratesAdditivelyToVersionTwo() throws {
        var legacy = StropheProjectData.blank()
        legacy.version = 1
        legacy.interchangeDocuments = nil
        legacy.timeline = nil

        let encodedLegacy = try JSONEncoder().encode(legacy)
        let decodedLegacy = try JSONDecoder().decode(StropheProjectData.self, from: encodedLegacy)
        let migrated = try StropheProjectMigrator.migrate(decodedLegacy)

        XCTAssertEqual(migrated.version, StropheProjectData.currentVersion)
        XCTAssertEqual(migrated.interchangeDocuments, [])
        XCTAssertEqual(migrated.timeline, ProjectTimelineState())
        XCTAssertEqual(migrated.tracks, legacy.tracks)
    }

    @MainActor
    func testFutureProjectVersionIsRejectedWithoutMutation() {
        var future = StropheProjectData.blank()
        future.version = StropheProjectData.currentVersion + 1

        XCTAssertThrowsError(try StropheProjectMigrator.migrate(future)) { error in
            guard case StropheProjectMigrationError.newerProjectVersion(let found, let supported) = error
            else {
                return XCTFail("Unexpected migration error: \(error)")
            }
            XCTAssertEqual(found, StropheProjectData.currentVersion + 1)
            XCTAssertEqual(supported, StropheProjectData.currentVersion)
        }
    }

    @MainActor
    func testWholeWordSearchFindsLaterValidOccurrence() {
        let options = SubtitleSearchOptions(
            isCaseSensitive: false,
            usesRegularExpression: false,
            matchesWholeWords: true
        )
        XCTAssertTrue(
            SubtitleEditingTools.matches(
                "concatenate cat",
                query: "cat",
                options: options
            )
        )
        XCTAssertFalse(
            SubtitleEditingTools.matches(
                "concatenate category",
                query: "cat",
                options: options
            )
        )
    }

    @MainActor
    func testStatisticsDetectGapsAndOverlaps() {
        let items = [
            SubtitleItem(text: "one", startTime: 0, endTime: 1),
            SubtitleItem(text: "two words", startTime: 1.5, endTime: 3),
            SubtitleItem(text: "three", startTime: 2.5, endTime: 4)
        ]
        let statistics = SubtitleEditingTools.statistics(for: items)

        XCTAssertEqual(statistics.totalCount, 3)
        XCTAssertEqual(statistics.gapCount, 1)
        XCTAssertEqual(statistics.overlapCount, 1)
        XCTAssertEqual(statistics.wordCount, 4)
    }

    @MainActor
    func testEmbeddedSubtitleTracksKeepLanguagesSeparateAndRespectExportPolicy() {
        let project = SubtitleProject()
        project.items = [
            SubtitleItem(
                text: "Primary",
                startTime: 0,
                endTime: 1,
                groupID: StyleAndGroupStore.DefaultGroupID.group1,
                languageCode: "en"
            ),
            SubtitleItem(
                text: "译文",
                startTime: 0,
                endTime: 1,
                groupID: StyleAndGroupStore.DefaultGroupID.groupA,
                languageCode: "zh"
            ),
            SubtitleItem(
                text: "Draft must not ship",
                startTime: 0,
                endTime: 1,
                groupID: StyleAndGroupStore.DefaultGroupID.groupB,
                languageCode: "en"
            )
        ]

        let tracks = EmbeddedSubtitleTrackBuilder.tracks(for: project)

        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(Set(tracks.compactMap(\.languageCode)), ["en", "zh"])
        XCTAssertEqual(tracks.flatMap(\.cues).map(\.text), ["Primary", "译文"])
    }

    @MainActor
    func testAdvancedExportSettingsResolveRangeAndAudioSelection() throws {
        var settings = HardSubtitleVideoExportSettings()
        settings.usesProjectRange = true
        settings.rangeStartSeconds = 12.5
        settings.rangeEndSeconds = 18
        settings.includedAudioTrackOrdinals = [1, 3]

        XCTAssertEqual(
            try settings.resolvedTimeRange(maxDuration: 20),
            12.5..<18
        )
        XCTAssertFalse(settings.includesAudioTrack(ordinal: 0))
        XCTAssertTrue(settings.includesAudioTrack(ordinal: 1))
        XCTAssertTrue(settings.includesAudioTrack(ordinal: 3))
    }

    @MainActor
    func testRollingBackupPrunesAndRestoresMigratedProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StropheBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        var projectData = StropheProjectData.blank()
        projectData.version = 1
        let projectID = try XCTUnwrap(projectData.metadata.projectID)
        let encoded = try JSONEncoder().encode(projectData)

        for index in 0..<35 {
            ProjectBackupStore.archive(
                encoded,
                projectID: projectID,
                sourceURL: URL(fileURLWithPath: "/Projects/Feature Cut.strophe"),
                createdAt: Date(timeIntervalSince1970: Double(index)),
                rootDirectoryOverride: root
            )
        }

        let snapshots = ProjectBackupStore.snapshots(
            projectID: projectID,
            rootDirectoryOverride: root
        )
        XCTAssertEqual(
            snapshots.count,
            ProjectBackupStore.maximumSnapshotsPerProject
        )
        XCTAssertTrue(
            snapshots.allSatisfy { $0.sourceFileName == "Feature Cut.strophe" }
        )
        let restored = try ProjectBackupStore.load(try XCTUnwrap(snapshots.first))
        XCTAssertEqual(restored.version, StropheProjectData.currentVersion)
        XCTAssertEqual(restored.metadata.projectID, projectID)
    }
}
