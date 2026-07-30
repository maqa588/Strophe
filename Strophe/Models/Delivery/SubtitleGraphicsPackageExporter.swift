//
//  SubtitleGraphicsPackageExporter.swift
//  Strophe
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Exports rendered subtitle assets for NLEs that cannot preserve Strophe's
/// complete style model as editable text.
///
/// Premiere receives one transparent, full-canvas PNG per cue plus an FCP 7
/// XML timeline. After Effects receives one frame sequence per cue plus a JSX
/// importer. Keeping each cue in its own sequence avoids generating empty
/// frames for gaps in the programme while retaining Karaoke/fade animation.
enum SubtitleGraphicsPackageExporter {
    private struct CueAsset {
        var cue: ResolvedSubtitleCue
        var filename: String
        var startFrame: Int64
        var endFrame: Int64
    }

    private static let imageContext = CIContext(options: [
        .cacheIntermediates: false
    ])

    @MainActor
    static func premiereXMLPNG(project: SubtitleProject) throws -> Data {
        let cues = project.resolvedSubtitleCues()
            .filter(validCue)
            .sorted(by: renderOrder)
        guard !cues.isEmpty else {
            throw ProfessionalSubtitleDeliveryError.noTimedSubtitles
        }

        let canvasSize = ProfessionalSubtitleDeliveryExporter
            .resolvedCanvasSize(project.videoSize)
        let frameRate = ProfessionalFrameRate.nearest(
            to: project.videoFrameRate
        )
        let staticCues = cues.map(flattenedStaticCue)
        var entries: [StoredZIPEntry] = []
        var assets: [CueAsset] = []

        for (index, cue) in staticCues.enumerated() {
            let filename = String(
                format: "Media/subtitle-%05d.png",
                index + 1
            )
            let presentationTime = cue.startTime
                + max(0, cue.endTime - cue.startTime) / 2
            let image = try renderCue(
                cue,
                allCues: staticCues,
                at: presentationTime,
                canvasSize: canvasSize,
                collisionMode: project.subtitleCollisionMode,
                rendersKaraoke: false
            )
            entries.append(
                StoredZIPEntry(
                    path: filename,
                    data: try pngData(image)
                )
            )
            assets.append(
                CueAsset(
                    cue: cue,
                    filename: filename,
                    startFrame: frameIndex(
                        cue.startTime,
                        frameRate: frameRate,
                        rounding: .down
                    ),
                    endFrame: max(
                        frameIndex(
                            cue.startTime,
                            frameRate: frameRate,
                            rounding: .down
                        ) + 1,
                        frameIndex(
                            cue.endTime,
                            frameRate: frameRate,
                            rounding: .up
                        )
                    )
                )
            )
        }

        entries.insert(
            StoredZIPEntry(
                path: "sequence.xml",
                data: Data(
                    premiereXML(
                        projectName: project.documentDisplayName,
                        assets: assets,
                        canvasSize: canvasSize,
                        frameRate: frameRate
                    ).utf8
                )
            ),
            at: 0
        )
        entries.append(
            StoredZIPEntry(
                path: "README.txt",
                data: Data(premiereReadme.utf8)
            )
        )
        return StoredZIPWriter.archive(entries)
    }

    @MainActor
    static func afterEffectsPNGSequence(
        project: SubtitleProject
    ) throws -> Data {
        let cues = project.resolvedSubtitleCues()
            .filter(validCue)
            .sorted(by: renderOrder)
        guard !cues.isEmpty else {
            throw ProfessionalSubtitleDeliveryError.noTimedSubtitles
        }

        let canvasSize = ProfessionalSubtitleDeliveryExporter
            .resolvedCanvasSize(project.videoSize)
        let frameRate = ProfessionalFrameRate.nearest(
            to: project.videoFrameRate
        )
        var entries: [StoredZIPEntry] = []
        var manifestCues: [[String: Any]] = []

        for (cueIndex, cue) in cues.enumerated() {
            let startFrame = frameIndex(
                cue.startTime,
                frameRate: frameRate,
                rounding: .down
            )
            let endFrame = max(
                startFrame + 1,
                frameIndex(
                    cue.endTime,
                    frameRate: frameRate,
                    rounding: .up
                )
            )
            let folder = String(format: "PNG/cue-%05d", cueIndex + 1)
            let frameCount = endFrame - startFrame

            for localFrame in 0..<frameCount {
                let globalFrame = startFrame + localFrame
                let presentationTime = (
                    Double(globalFrame) + 0.5
                ) / frameRate.value
                let image = try renderCue(
                    cue,
                    allCues: cues,
                    at: presentationTime,
                    canvasSize: canvasSize,
                    collisionMode: project.subtitleCollisionMode,
                    rendersKaraoke: true
                )
                let frameName = String(
                    format: "%@/frame-%06lld.png",
                    folder,
                    localFrame + 1
                )
                entries.append(
                    StoredZIPEntry(
                        path: frameName,
                        data: try pngData(image)
                    )
                )
            }

            manifestCues.append([
                "id": cue.id.uuidString,
                "text": cue.text,
                "folder": folder,
                "firstFrame": "\(folder)/frame-000001.png",
                "frameCount": frameCount,
                "startFrame": startFrame,
                "endFrame": endFrame,
                "startTime": cue.startTime,
                "endTime": cue.endTime,
                "track": cue.trackIndex,
                "layer": cue.layer,
                "hasKaraoke": cue.karaoke != nil
            ])
        }

        let manifest: [String: Any] = [
            "format": "Strophe After Effects PNG Sequence",
            "version": 1,
            "compositionName": project.documentDisplayName.isEmpty
                ? "Strophe Subtitles"
                : project.documentDisplayName,
            "width": Int(canvasSize.width),
            "height": Int(canvasSize.height),
            "frameRate": frameRate.value,
            "duration": cues.map(\.endTime).max() ?? 0,
            "cues": manifestCues
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        entries.insert(
            StoredZIPEntry(path: "manifest.json", data: manifestData),
            at: 0
        )
        entries.insert(
            StoredZIPEntry(
                path: "import-strophe.jsx",
                data: Data(afterEffectsImporterScript.utf8)
            ),
            at: 1
        )
        entries.append(
            StoredZIPEntry(
                path: "README.txt",
                data: Data(afterEffectsReadme.utf8)
            )
        )
        return StoredZIPWriter.archive(entries)
    }

    private static func validCue(_ cue: ResolvedSubtitleCue) -> Bool {
        cue.startTime.isFinite
            && cue.endTime.isFinite
            && cue.endTime > cue.startTime
            && !cue.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
    }

    private static func renderOrder(
        _ lhs: ResolvedSubtitleCue,
        _ rhs: ResolvedSubtitleCue
    ) -> Bool {
        if lhs.layer != rhs.layer { return lhs.layer < rhs.layer }
        if lhs.trackIndex != rhs.trackIndex {
            return lhs.trackIndex < rhs.trackIndex
        }
        if lhs.startTime != rhs.startTime {
            return lhs.startTime < rhs.startTime
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func flattenedStaticCue(
        _ source: ResolvedSubtitleCue
    ) -> ResolvedSubtitleCue {
        var cue = source
        cue.karaoke = nil
        cue.usesFadeInOut = false
        return cue
    }

    private static func frameIndex(
        _ seconds: Double,
        frameRate: ProfessionalFrameRate,
        rounding: FloatingPointRoundingRule
    ) -> Int64 {
        Int64((max(0, seconds) * frameRate.value).rounded(rounding))
    }

    private static func renderCue(
        _ targetCue: ResolvedSubtitleCue,
        allCues: [ResolvedSubtitleCue],
        at presentationTime: Double,
        canvasSize: CGSize,
        collisionMode: SubtitleCollisionMode,
        rendersKaraoke: Bool
    ) throws -> CGImage {
        let scene = SubtitleFrameSceneResolver.resolve(
            cues: allCues,
            at: presentationTime,
            canvasSize: canvasSize,
            collisionMode: collisionMode,
            forcedCueIDs: [targetCue.id]
        ) { cue in
            if rendersKaraoke, cue.karaoke != nil {
                return KaraokeFrameRenderer.shared.metrics(
                    cue: cue,
                    canvasSize: canvasSize
                )
            }
            return SubtitleBitmapRenderer.metrics(
                cue: cue,
                canvasSize: canvasSize
            )
        }
        guard let item = scene.items.first(where: {
            $0.id == targetCue.id
        }) else {
            throw ProfessionalSubtitleDeliveryError.cannotRenderGraphics(
                targetCue.text
            )
        }

        let sourceImage: CGImage?
        if rendersKaraoke, item.cue.karaoke != nil {
            sourceImage = KaraokeFrameRenderer.shared.makeCGImage(
                cue: item.cue,
                presentationTime: presentationTime,
                canvasSize: canvasSize
            )
        } else {
            sourceImage = SubtitleBitmapRenderer.makeImage(
                cue: item.cue,
                canvasSize: canvasSize
            )
        }
        guard let sourceImage else {
            throw ProfessionalSubtitleDeliveryError.cannotRenderGraphics(
                targetCue.text
            )
        }

        let bounds = CGRect(origin: .zero, size: canvasSize)
        let transparent = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        ).cropped(to: bounds)
        let coreImageOrigin = CGPoint(
            x: item.origin.x,
            y: canvasSize.height - item.origin.y - item.size.height
        )
        var overlay = CIImage(cgImage: sourceImage).transformed(
            by: CGAffineTransform(
                translationX: coreImageOrigin.x.rounded(.down),
                y: coreImageOrigin.y.rounded(.down)
            )
        )
        let opacity = item.cue.opacity(at: presentationTime)
        if opacity < 1 {
            overlay = overlay.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputAVector": CIVector(
                        x: 0,
                        y: 0,
                        z: 0,
                        w: CGFloat(opacity)
                    )
                ]
            )
        }
        let output = overlay.composited(over: transparent)
        guard let image = imageContext.createCGImage(output, from: bounds) else {
            throw ProfessionalSubtitleDeliveryError.cannotRenderGraphics(
                targetCue.text
            )
        }
        return image
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ProfessionalSubtitleDeliveryError.cannotEncodePNG
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ProfessionalSubtitleDeliveryError.cannotEncodePNG
        }
        return data as Data
    }

    private static func premiereXML(
        projectName: String,
        assets: [CueAsset],
        canvasSize: CGSize,
        frameRate: ProfessionalFrameRate
    ) -> String {
        let sequenceName = projectName.isEmpty
            ? "Strophe Subtitles"
            : projectName
        let sequenceDuration = max(
            1,
            assets.map(\.endFrame).max() ?? 1
        )
        let trackKeys = Array(
            Set(assets.map { "\($0.cue.layer):\($0.cue.trackIndex)" })
        ).sorted { lhs, rhs in
            let l = lhs.split(separator: ":").compactMap { Int($0) }
            let r = rhs.split(separator: ":").compactMap { Int($0) }
            if l.first != r.first {
                return (l.first ?? 0) < (r.first ?? 0)
            }
            return (l.dropFirst().first ?? 0)
                < (r.dropFirst().first ?? 0)
        }

        let tracks = trackKeys.map { key in
            let clipItems = assets.enumerated().compactMap {
                index, asset -> String? in
                let assetKey = "\(asset.cue.layer):\(asset.cue.trackIndex)"
                guard assetKey == key else { return nil }
                let duration = max(1, asset.endFrame - asset.startFrame)
                let fileID = "file-\(index + 1)"
                let clipID = "clipitem-\(index + 1)"
                let displayName = asset.cue.text
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                return """
                      <clipitem id="\(clipID)">
                        <name>\(xmlEscape(displayName))</name>
                        <duration>\(duration)</duration>
                        \(xmlRate(frameRate))
                        <start>\(asset.startFrame)</start>
                        <end>\(asset.endFrame)</end>
                        <in>0</in>
                        <out>\(duration)</out>
                        <file id="\(fileID)">
                          <name>\(xmlEscape(
                              String(asset.filename.split(separator: "/").last ?? "")
                          ))</name>
                          <pathurl>./\(xmlEscape(asset.filename))</pathurl>
                          \(xmlRate(frameRate))
                          <duration>\(duration)</duration>
                          <media>
                            <video>
                              \(sampleCharacteristics(
                                  canvasSize: canvasSize,
                                  frameRate: frameRate
                              ))
                            </video>
                          </media>
                        </file>
                        <enabled>TRUE</enabled>
                        <anamorphic>FALSE</anamorphic>
                        <alphatype>straight</alphatype>
                      </clipitem>
                """
            }
            .joined(separator: "\n")
            return """
                    <track>
                \(clipItems)
                      <enabled>TRUE</enabled>
                      <locked>FALSE</locked>
                    </track>
            """
        }
        .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE xmeml>
        <xmeml version="5">
          <sequence id="sequence-1">
            <name>\(xmlEscape(sequenceName))</name>
            <duration>\(sequenceDuration)</duration>
            \(xmlRate(frameRate))
            <media>
              <video>
                <format>
                  \(sampleCharacteristics(
                      canvasSize: canvasSize,
                      frameRate: frameRate
                  ))
                </format>
        \(tracks)
              </video>
            </media>
          </sequence>
        </xmeml>
        """
    }

    private static func xmlRate(
        _ frameRate: ProfessionalFrameRate
    ) -> String {
        """
        <rate>
          <timebase>\(frameRate.nominalFramesPerSecond)</timebase>
          <ntsc>\(frameRate.denominator == 1_001 ? "TRUE" : "FALSE")</ntsc>
        </rate>
        """
    }

    private static func sampleCharacteristics(
        canvasSize: CGSize,
        frameRate: ProfessionalFrameRate
    ) -> String {
        """
        <samplecharacteristics>
          \(xmlRate(frameRate))
          <width>\(Int(canvasSize.width))</width>
          <height>\(Int(canvasSize.height))</height>
          <anamorphic>FALSE</anamorphic>
          <pixelaspectratio>square</pixelaspectratio>
          <fielddominance>none</fielddominance>
        </samplecharacteristics>
        """
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static let premiereReadme = """
    Strophe Premiere graphics package

    1. Extract this ZIP archive without changing its folder structure.
    2. Import sequence.xml into Adobe Premiere Pro.
    3. If Premiere asks for media, relink the first missing item to the Media folder.
       The remaining PNG files should relink automatically.

    The XML contains editable timing and tracks. Each subtitle is a transparent
    full-frame PNG, so typography, outlines, rotation, anchoring and placement
    are preserved. Karaoke animation is intentionally flattened in this package;
    use Strophe's Alpha video export when frame-accurate animation is required.
    """

    private static let afterEffectsReadme = """
    Strophe After Effects PNG-sequence package

    1. Extract this ZIP archive without changing its folder structure.
    2. In After Effects choose File > Scripts > Run Script File.
    3. Select import-strophe.jsx from the extracted folder.

    The script creates a composition and places one transparent PNG sequence per
    subtitle cue. Karaoke, fades, placement, collision resolution and supported
    Strophe effects are rendered frame by frame.
    """

    private static let afterEffectsImporterScript = #"""
    (function () {
        app.beginUndoGroup("Import Strophe Subtitle Sequences");
        try {
            var scriptFile = new File($.fileName);
            var root = scriptFile.parent;
            var manifestFile = new File(root.fsName + "/manifest.json");
            if (!manifestFile.exists) {
                throw new Error("manifest.json was not found next to the script.");
            }
            manifestFile.encoding = "UTF-8";
            manifestFile.open("r");
            var manifest = JSON.parse(manifestFile.read());
            manifestFile.close();

            var comp = app.project.items.addComp(
                manifest.compositionName || "Strophe Subtitles",
                manifest.width,
                manifest.height,
                1,
                Math.max(manifest.duration, 1 / manifest.frameRate),
                manifest.frameRate
            );

            for (var i = 0; i < manifest.cues.length; i++) {
                var cue = manifest.cues[i];
                var firstFrame = new File(root.fsName + "/" + cue.firstFrame);
                if (!firstFrame.exists) {
                    throw new Error("Missing PNG: " + cue.firstFrame);
                }
                var options = new ImportOptions(firstFrame);
                options.sequence = true;
                options.forceAlphabetical = true;
                var footage = app.project.importFile(options);
                footage.mainSource.conformFrameRate = manifest.frameRate;

                var layer = comp.layers.add(footage);
                layer.name = cue.text || ("Subtitle " + (i + 1));
                layer.startTime = cue.startFrame / manifest.frameRate;
                layer.inPoint = cue.startTime;
                layer.outPoint = cue.endTime;
            }
            comp.openInViewer();
        } catch (error) {
            alert("Strophe import failed:\n" + error.toString());
        } finally {
            app.endUndoGroup();
        }
    }());
    """#
}
