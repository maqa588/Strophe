#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Strophe

final class KaraokeUXSnapshotTests: XCTestCase {
    @MainActor
    func testRendersKaraokePreviewAndEditorSnapshot() throws {
        let project = SubtitleProject()
        let cueStart = 0.8
        let text = "君のことが好き"
        let words = [
            SubtitleWordTiming(text: "君", startTime: 1.0, endTime: 1.42),
            SubtitleWordTiming(text: "の", startTime: 1.42, endTime: 1.73),
            SubtitleWordTiming(text: "こと", startTime: 1.73, endTime: 2.58),
            SubtitleWordTiming(text: "が", startTime: 2.58, endTime: 2.92),
            SubtitleWordTiming(text: "好き", startTime: 2.92, endTime: 4.05)
        ]
        var program = try XCTUnwrap(
            KaraokeProgram.fromAlignedWords(
                words,
                cueText: text,
                cueStartTime: cueStart,
                cueEndTime: 4.4,
                template: .glow
            )
        )
        program.template.activeColorHex = "#46E6FFFF"
        let item = SubtitleItem(
            text: text,
            startTime: cueStart,
            endTime: 4.4,
            layer: 2,
            karaoke: program
        )
        project.items = [item]
        project.selectedIDs = [item.id]
        project.karaokeEditingItemID = item.id
        project.videoSize = CGSize(width: 1920, height: 1080)
        project.currentTime = 2.18
        project.showHardSubtitles = true
        let root = VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.black
                HardSubtitleOverlayView(project: project)
                Text("SHARED PREVIEW / EXPORT STATE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.48))
                    .padding(12)
            }
            .frame(height: 300)

            KaraokeEditorPanel(project: project)
        }
        .frame(width: 1_000, height: 466)
        .background(Color.stropheSecondaryBackground)
        .preferredColorScheme(.dark)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 1_000, height: 466)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        hostingView.layoutSubtreeIfNeeded()
        // Give TimelineView, localized controls and Core Image one display pass
        // before caching the host. Attaching the host to an off-screen window
        // prevents a headless XCTest process from dropping the editor subtree.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(
            in: hostingView.bounds,
            to: representation
        )
        let png = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )
        XCTAssertGreaterThan(png.count, 10_000)
        XCTAssertTrue(
            panelRegionContainsRenderedContent(representation),
            "The snapshot captured the preview but not the Karaoke editor."
        )

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Strophe-Karaoke-UX.png")
        try png.write(to: outputURL, options: .atomic)
        print("KARAOKE_UX_SNAPSHOT=\(outputURL.path)")
    }

    private func panelRegionContainsRenderedContent(
        _ representation: NSBitmapImageRep
    ) -> Bool {
        // NSBitmapImageRep pixel coordinates are top-left based here; the
        // editor occupies the bottom third of the composed snapshot.
        let sampledStart = max(0, representation.pixelsHigh * 2 / 3)
        let step = max(2, representation.pixelsWide / 160)
        var visibleSamples = 0
        var totalSamples = 0

        for y in stride(
            from: sampledStart,
            to: representation.pixelsHigh,
            by: step
        ) {
            for x in stride(
                from: step,
                to: representation.pixelsWide,
                by: step
            ) {
                guard let color = representation.colorAt(x: x, y: y)?
                    .usingColorSpace(.sRGB) else {
                    continue
                }
                totalSamples += 1
                let luminance = color.redComponent * 0.2126
                    + color.greenComponent * 0.7152
                    + color.blueComponent * 0.0722
                if color.alphaComponent > 0.5, luminance > 0.04 {
                    visibleSamples += 1
                }
            }
        }

        return totalSamples > 0 && visibleSamples * 4 > totalSamples
    }
}
#endif
