//
//  KaraokeEditorPanel.swift
//  Strophe
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct KaraokeEditorPanel: View {
    @ObservedObject var project: SubtitleProject

    @State private var selectedUnitID: UUID?
    @State private var boundaryDraft: BoundaryDraft?
    @State private var templateEditSession: TemplateEditSession?
    @State private var delayedTemplateCommit: Task<Void, Never>?

    static func preferredHeight(for item: SubtitleItem?) -> CGFloat {
        guard let item, item.activeKaraoke != nil else { return 0 }
        return 118
    }

    var body: some View {
        if let item = project.karaokeEditorItem,
           let startTime = item.startTime,
           let endTime = item.endTime {
            VStack(alignment: .leading, spacing: 8) {
                if let program = item.activeKaraoke {
                    templateControls(item: item, program: program)
                    unitTimeline(
                        item: item,
                        program: program,
                        cueStartTime: startTime,
                        cueDuration: max(0.001, endTime - startTime)
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(
                maxWidth: .infinity,
                minHeight: Self.preferredHeight(for: item),
                maxHeight: Self.preferredHeight(for: item),
                alignment: .topLeading
            )
            .background(Color.stropheSecondaryBackground)
            .overlay {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.stropheTimelineDivider.opacity(0.7))
                        .frame(height: 1)
                    Spacer()
                    Rectangle()
                        .fill(Color.stropheTimelineDivider)
                        .frame(height: 1)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("karaokeEditorPanel")
            .stropheOnChange(of: item.id) { _ in
                finishTemplateEdit()
                selectedUnitID = item.karaoke?.units.first?.id
                boundaryDraft = nil
            }
            .stropheOnChange(of: item.karaoke?.units.map(\.id)) { unitIDs in
                if let selectedUnitID, unitIDs?.contains(selectedUnitID) == false {
                    self.selectedUnitID = unitIDs?.first
                }
            }
            .onAppear {
                selectedUnitID = selectedUnitID ?? item.karaoke?.units.first?.id
            }
            .onDisappear {
                finishTemplateEdit()
                delayedTemplateCommit?.cancel()
            }
        }
    }

    private func templateControls(
        item: SubtitleItem,
        program: KaraokeProgram
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Picker(
                    stropheLocalizedString("karaoke_template"),
                    selection: presetBinding(item: item, program: program)
                ) {
                    ForEach(KaraokeTemplatePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.subheadline.weight(.medium))
                .controlSize(.small)
                .frame(width: 100)
                .accessibilityIdentifier("karaokePresetPicker")

                Divider()
                    .frame(height: 20)

                Picker(
                    stropheLocalizedString("karaoke_reveal"),
                    selection: revealBinding(item: item, program: program)
                ) {
                    Text(stropheLocalizedString("karaoke_reveal_step"))
                        .tag(KaraokeRevealMode.step)
                    Text(stropheLocalizedString("karaoke_reveal_sweep"))
                        .tag(KaraokeRevealMode.sweep)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
                .accessibilityIdentifier("karaokeRevealPicker")

                Divider()
                    .frame(height: 20)

                HStack(spacing: 8) {
                    colorControl(
                        title: stropheLocalizedString("karaoke_inactive_color"),
                        color: colorBinding(
                            item: item,
                            program: program,
                            keyPath: \.inactiveColorHex
                        )
                    )
                    colorControl(
                        title: stropheLocalizedString("karaoke_active_color"),
                        color: colorBinding(
                            item: item,
                            program: program,
                            keyPath: \.activeColorHex
                        )
                    )
                }

                Divider()
                    .frame(height: 20)

                effectSlider(
                    title: stropheLocalizedString("karaoke_pop"),
                    icon: "arrow.up.left.and.arrow.down.right",
                    value: templateDoubleBinding(
                        item: item,
                        program: program,
                        keyPath: \.popScale
                    ),
                    range: 1...1.35,
                    display: String(
                        format: "%.2f×",
                        program.template.popScale
                    ),
                    itemID: item.id
                )

                effectSlider(
                    title: stropheLocalizedString("karaoke_glow"),
                    icon: "sun.max.fill",
                    value: templateDoubleBinding(
                        item: item,
                        program: program,
                        keyPath: \.glowRadius
                    ),
                    range: 0...24,
                    display: String(
                        format: "%.0f",
                        program.template.glowRadius
                    ),
                    itemID: item.id
                )
            }
            .padding(.horizontal, 10)
            .controlSize(.small)
        }
        .frame(height: 36)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func colorControl(
        title: String,
        color: Binding<Color>
    ) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ColorPicker(title, selection: color, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 24)
        }
    }

    private func effectSlider(
        title: String,
        icon: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String,
        itemID: UUID
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(
                value: value,
                in: range,
                onEditingChanged: { isEditing in
                    if isEditing {
                        beginTemplateEdit(itemID: itemID)
                    } else {
                        finishTemplateEdit()
                    }
                }
            )
            .frame(width: 76)
            Text(display)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 29, alignment: .trailing)
        }
    }

    private func unitTimeline(
        item: SubtitleItem,
        program: KaraokeProgram,
        cueStartTime: Double,
        cueDuration: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Spacer()

                if let selected = displayedUnits(program: program).first(
                    where: { $0.id == selectedUnitID }
                ) {
                    let timingSummary =
                        "\(selected.text)  \(timeLabel(selected.startOffset)) – \(timeLabel(selected.endOffset))"
                    Text(timingSummary)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(timingSummary)
                    .accessibilityIdentifier("karaokeSelectedUnitTiming")
                }
            }

            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let units = displayedUnits(program: program)
                let displaySpans = contiguousDisplaySpans(for: units)
                let displayStart = displaySpans.first?.lowerBound ?? 0
                let displayEnd = displaySpans.last?.upperBound ?? cueDuration
                let displayDuration = max(0.001, displayEnd - displayStart)
                let activeColor = ResolvedRGBAColor(
                    hex: program.template.activeColorHex
                )?.color ?? Color.stropheAccent
                let inactiveColor = ResolvedRGBAColor(
                    hex: program.template.inactiveColorHex
                )?.color ?? Color.secondary
                let frameFloor = max(
                    0.001,
                    1 / max(project.videoFrameRate, 1)
                )

                // `SubtitleProject.currentTime` intentionally is not published
                // on every frame because that would rebuild the whole editor.
                // Drive only this lightweight unit strip from the display clock
                // and sample the authoritative player time on every tick.
                TimelineView(
                    .animation(minimumInterval: 1 / 60, paused: false)
                ) { timeline in
                    let playbackTime = resolvedPlaybackTime(at: timeline.date)
                    let localPlayhead = playbackTime - cueStartTime
                    let playbackUnitID = playbackSelectedUnitID(
                        units: units,
                        localPlayhead: localPlayhead,
                        cueDuration: cueDuration
                    )

                    ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.045))

                    ForEach(Array(units.enumerated()), id: \.element.id) { index, unit in
                        let span = displaySpans[index]
                        let x = CGFloat(
                            (span.lowerBound - displayStart) / displayDuration
                        ) * width
                        let rawWidth = CGFloat(
                            (span.upperBound - span.lowerBound) / displayDuration
                        ) * width
                        let unitWidth = max(4, rawWidth - 1)
                        let phase = phase(
                            unit: unit,
                            localPlayhead: localPlayhead
                        )

                        Button {
                            selectedUnitID = unit.id
                            project.seek(to: cueStartTime + unit.startOffset)
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(
                                        unitFill(
                                            phase: phase,
                                            activeColor: activeColor,
                                            inactiveColor: inactiveColor
                                        )
                                    )
                                Text(unit.text)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(
                                        phase == .upcoming
                                            ? Color.primary.opacity(0.72)
                                            : Color.white
                                    )
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .padding(.horizontal, 3)
                            }
                            .frame(width: unitWidth, height: 32)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(
                                        selectedUnitID == unit.id
                                            ? Color.white.opacity(0.9)
                                            : Color.clear,
                                        lineWidth: 2
                                    )
                            }
                            .overlay(alignment: .topTrailing) {
                                if selectedUnitID == unit.id {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 6, weight: .bold))
                                        .foregroundStyle(Color.white)
                                        .padding(3)
                                        .background(
                                            Color.black.opacity(0.35),
                                            in: Circle()
                                        )
                                        .padding(2)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .position(
                            x: min(width - unitWidth / 2, max(unitWidth / 2, x + unitWidth / 2)),
                            y: 21
                        )
                        .accessibilityLabel(
                            String(
                                format: stropheLocalizedString("karaoke_unit_accessibility_format"),
                                unit.text,
                                unit.startOffset,
                                unit.endOffset
                            )
                        )
                        .accessibilityIdentifier("karaokeUnit-\(unit.id.uuidString)")
                    }

                    ForEach(
                        Array(units.dropLast().enumerated()),
                        id: \.element.id
                    ) { index, unit in
                        let boundaryX = CGFloat(
                            (displaySpans[index].upperBound - displayStart)
                                / displayDuration
                        ) * width
                        let boundaryRange = boundaryAccessibilityRange(
                            program: program,
                            unitID: unit.id
                        )

                        KaraokeBoundaryHandle(
                            value: unit.endOffset,
                            range: boundaryRange,
                            timelineWidth: width,
                            cueDuration: displayDuration,
                            step: frameFloor,
                            label: stropheLocalizedString(
                                "karaoke_adjust_boundary"
                            ),
                            identifier: "karaokeBoundary-\(unit.id.uuidString)",
                            onChanged: { proposed in
                                boundaryDraft = BoundaryDraft(
                                    itemID: item.id,
                                    precedingUnitID: unit.id,
                                    offset: proposed
                                )
                            },
                            onEnded: { proposed in
                                project.updateKaraokeBoundary(
                                    itemID: item.id,
                                    precedingUnitID: unit.id,
                                    to: proposed
                                )
                                boundaryDraft = nil
                            }
                        )
                            .frame(width: 18, height: 44)
                            .position(
                                x: min(width - 2, max(2, boundaryX)),
                                y: 21
                            )
                            .zIndex(10)
                    }

                    if localPlayhead >= displayStart,
                       localPlayhead <= displayEnd {
                        let playheadX = CGFloat(
                            (localPlayhead - displayStart) / displayDuration
                        ) * width
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 1.5, height: 42)
                            .shadow(color: .black.opacity(0.6), radius: 1)
                            .position(x: playheadX, y: 21)
                            .allowsHitTesting(false)
                    }
                }
                .task(id: playbackUnitID) {
                    guard boundaryDraft == nil,
                          let playbackUnitID,
                          selectedUnitID != playbackUnitID else {
                        return
                    }
                    selectedUnitID = playbackUnitID
                }
                }
            }
            .frame(height: 44)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("karaokeUnitTimeline")
        }
    }

    /// Returns the same live clock used by subtitle preview. Engine time wins
    /// while playing; the project clock remains authoritative for scrubbing,
    /// frame stepping and the short period before an engine is installed.
    private func resolvedPlaybackTime(at date: Date) -> Double {
        if project.isScrubbing || project.isSeeking {
            return project.currentTime.isFinite ? project.currentTime : 0
        }
        if let engineTime = project.activeEngine?.currentTime,
           engineTime.isFinite {
            return engineTime
        }
        let predicted = project.referenceTime
            + date.timeIntervalSince(project.referenceDate) * project.playbackRate
        if predicted.isFinite {
            return max(0, predicted)
        }
        return project.currentTime.isFinite ? project.currentTime : 0
    }

    private func presetBinding(
        item: SubtitleItem,
        program: KaraokeProgram
    ) -> Binding<KaraokeTemplatePreset> {
        Binding(
            get: { program.template.preset },
            set: { preset in
                finishTemplateEdit()
                var configuration = program.template
                configuration.applyPreset(preset)
                project.updateKaraokeTemplate(
                    id: item.id,
                    configuration: configuration
                )
            }
        )
    }

    private func revealBinding(
        item: SubtitleItem,
        program: KaraokeProgram
    ) -> Binding<KaraokeRevealMode> {
        Binding(
            get: { program.template.revealMode },
            set: { revealMode in
                finishTemplateEdit()
                var configuration = program.template
                configuration.revealMode = revealMode
                project.updateKaraokeTemplate(
                    id: item.id,
                    configuration: configuration
                )
            }
        )
    }

    private func colorBinding(
        item: SubtitleItem,
        program: KaraokeProgram,
        keyPath: WritableKeyPath<KaraokeTemplateConfiguration, String>
    ) -> Binding<Color> {
        Binding(
            get: {
                ResolvedRGBAColor(
                    hex: program.template[keyPath: keyPath]
                )?.color ?? .white
            },
            set: { color in
                beginTemplateEdit(itemID: item.id)
                var configuration = currentTemplate(for: item.id) ?? program.template
                configuration[keyPath: keyPath] = color.resolvedRGBA.hexString
                project.previewKaraokeTemplate(
                    id: item.id,
                    configuration: configuration
                )
                scheduleTemplateCommit()
            }
        )
    }

    private func templateDoubleBinding(
        item: SubtitleItem,
        program: KaraokeProgram,
        keyPath: WritableKeyPath<KaraokeTemplateConfiguration, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                currentTemplate(for: item.id)?[keyPath: keyPath]
                    ?? program.template[keyPath: keyPath]
            },
            set: { value in
                beginTemplateEdit(itemID: item.id)
                var configuration = currentTemplate(for: item.id) ?? program.template
                configuration[keyPath: keyPath] = value
                if keyPath == \KaraokeTemplateConfiguration.glowRadius,
                   value > 0,
                   configuration.glowIntensity <= 0 {
                    configuration.glowIntensity = 0.9
                }
                project.previewKaraokeTemplate(
                    id: item.id,
                    configuration: configuration
                )
            }
        )
    }

    private func beginTemplateEdit(itemID: UUID) {
        guard templateEditSession == nil,
              let configuration = currentTemplate(for: itemID) else {
            return
        }
        templateEditSession = TemplateEditSession(
            itemID: itemID,
            original: configuration
        )
    }

    private func scheduleTemplateCommit() {
        delayedTemplateCommit?.cancel()
        delayedTemplateCommit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            finishTemplateEdit()
        }
    }

    private func finishTemplateEdit() {
        delayedTemplateCommit?.cancel()
        delayedTemplateCommit = nil
        guard let session = templateEditSession,
              let final = currentTemplate(for: session.itemID) else {
            templateEditSession = nil
            return
        }
        templateEditSession = nil
        project.commitKaraokeTemplatePreview(
            id: session.itemID,
            originalConfiguration: session.original,
            finalConfiguration: final
        )
    }

    private func currentTemplate(
        for itemID: UUID
    ) -> KaraokeTemplateConfiguration? {
        project.items.first(where: { $0.id == itemID })?.karaoke?.template
    }

    private func displayedUnits(
        program: KaraokeProgram
    ) -> [KaraokeTimingUnit] {
        guard let boundaryDraft,
              let index = program.units.firstIndex(
                where: { $0.id == boundaryDraft.precedingUnitID }
              ),
              index + 1 < program.units.count else {
            return program.units
        }
        var units = program.units
        let frameFloor = max(0.001, 1 / max(project.videoFrameRate, 1))
        let lower = units[index].startOffset + frameFloor
        let upper = units[index + 1].endOffset - frameFloor
        let boundary = min(max(boundaryDraft.offset, lower), upper)
        units[index].endOffset = boundary
        units[index + 1].startOffset = boundary
        return units
    }

    /// The editor is a word-boundary tool, not a miniature copy of the cue
    /// timeline. Adjacent cells therefore share one visual boundary. Any
    /// aligner silence between two words is divided at its midpoint instead of
    /// becoming a large, uneditable blank area; the stored word times remain
    /// unchanged until the user drags that boundary.
    private func contiguousDisplaySpans(
        for units: [KaraokeTimingUnit]
    ) -> [ClosedRange<Double>] {
        guard let first = units.first else { return [] }
        guard units.count > 1 else {
            let end = max(first.endOffset, first.startOffset + 0.001)
            return [first.startOffset...end]
        }

        var boundaries = [first.startOffset]
        boundaries.reserveCapacity(units.count + 1)
        for index in 0..<(units.count - 1) {
            let midpoint = (
                units[index].endOffset + units[index + 1].startOffset
            ) / 2
            boundaries.append(max(boundaries.last! + 0.000_001, midpoint))
        }
        boundaries.append(
            max(boundaries.last! + 0.000_001, units.last!.endOffset)
        )

        return units.indices.map {
            boundaries[$0]...boundaries[$0 + 1]
        }
    }

    private func playbackSelectedUnitID(
        units: [KaraokeTimingUnit],
        localPlayhead: Double,
        cueDuration: Double
    ) -> UUID? {
        guard localPlayhead >= 0,
              localPlayhead <= cueDuration,
              let first = units.first else {
            return nil
        }
        return units.last(where: { $0.startOffset <= localPlayhead })?.id
            ?? first.id
    }

    private func boundaryAccessibilityRange(
        program: KaraokeProgram,
        unitID: UUID
    ) -> ClosedRange<Double> {
        guard let index = program.units.firstIndex(
            where: { $0.id == unitID }
        ),
        index + 1 < program.units.count else {
            return 0...1
        }
        let frameFloor = max(0.001, 1 / max(project.videoFrameRate, 1))
        let lower = program.units[index].startOffset + frameFloor
        let upper = program.units[index + 1].endOffset - frameFloor
        return upper > (lower + 0.001) ? lower...upper : lower...(lower + 0.005)
    }

    private func phase(
        unit: KaraokeTimingUnit,
        localPlayhead: Double
    ) -> KaraokeUnitRenderState.Phase {
        if localPlayhead < unit.startOffset { return .upcoming }
        if localPlayhead >= unit.endOffset { return .completed }
        return .active
    }

    private func unitFill(
        phase: KaraokeUnitRenderState.Phase,
        activeColor: Color,
        inactiveColor: Color
    ) -> Color {
        switch phase {
        case .upcoming: return inactiveColor.opacity(0.24)
        case .active: return activeColor.opacity(0.82)
        case .completed: return activeColor.opacity(0.58)
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        String(format: "%+.3fs", seconds)
    }

    private struct BoundaryDraft: Equatable {
        var itemID: UUID
        var precedingUnitID: UUID
        var offset: Double
    }

    private struct TemplateEditSession {
        var itemID: UUID
        var original: KaraokeTemplateConfiguration
    }
}

private struct KaraokeBoundaryHandle: View {
    var value: Double
    var range: ClosedRange<Double>
    var timelineWidth: CGFloat
    var cueDuration: Double
    var step: Double
    var label: String
    var identifier: String
    var onChanged: (Double) -> Void
    var onEnded: (Double) -> Void

    #if !os(macOS)
    @State private var dragStartValue: Double?
    #endif

    var body: some View {
        #if os(macOS)
        MacKaraokeBoundaryHandle(
            value: value,
            range: range,
            timelineWidth: timelineWidth,
            cueDuration: cueDuration,
            step: step,
            label: label,
            identifier: identifier,
            onChanged: onChanged,
            onEnded: onEnded
        )
        #else
        Capsule()
            .fill(Color.white.opacity(0.92))
            .frame(width: 3, height: 38)
            .overlay {
                Capsule()
                    .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
            }
            .frame(width: 18, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let initial = dragStartValue ?? value
                        if dragStartValue == nil {
                            dragStartValue = initial
                        }
                        onChanged(
                            clamped(
                                initial
                                    + Double(
                                        gesture.translation.width
                                            / max(1, timelineWidth)
                                    )
                                    * cueDuration
                            )
                        )
                    }
                    .onEnded { gesture in
                        let initial = dragStartValue ?? value
                        let final = clamped(
                            initial
                                + Double(
                                    gesture.translation.width
                                        / max(1, timelineWidth)
                                )
                                * cueDuration
                        )
                        dragStartValue = nil
                        onEnded(final)
                    }
            )
            .accessibilityRepresentation {
                let rangeSpan = max(0.001, range.upperBound - range.lowerBound)
                let safeRange = range.upperBound > range.lowerBound ? range : range.lowerBound...(range.lowerBound + 0.005)
                let safeStep = (step.isFinite && step > 0 && step <= rangeSpan / 2) ? step : max(0.0001, rangeSpan / 10)
                Slider(
                    value: Binding(
                        get: { value },
                        set: { adjusted in
                            let bounded = clamped(adjusted)
                            onChanged(bounded)
                            onEnded(bounded)
                        }
                    ),
                    in: safeRange,
                    step: safeStep
                )
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
            }
        #endif
    }

    private func clamped(_ proposed: Double) -> Double {
        min(max(proposed, range.lowerBound), range.upperBound)
    }
}

#if os(macOS)
private struct MacKaraokeBoundaryHandle: NSViewRepresentable {
    var value: Double
    var range: ClosedRange<Double>
    var timelineWidth: CGFloat
    var cueDuration: Double
    var step: Double
    var label: String
    var identifier: String
    var onChanged: (Double) -> Void
    var onEnded: (Double) -> Void

    func makeNSView(context: Context) -> KaraokeBoundaryHandleView {
        KaraokeBoundaryHandleView()
    }

    func updateNSView(
        _ nsView: KaraokeBoundaryHandleView,
        context: Context
    ) {
        nsView.configure(
            value: value,
            range: range,
            timelineWidth: timelineWidth,
            cueDuration: cueDuration,
            step: step,
            label: label,
            identifier: identifier,
            onChanged: onChanged,
            onEnded: onEnded
        )
    }
}

private final class KaraokeBoundaryHandleView: NSSlider {
    private var currentValue = 0.0
    private var allowedRange = 0.0...1.0
    private var timelineWidth: CGFloat = 1
    private var cueDuration = 1.0
    private var adjustmentStep = 1 / 30.0
    private var onChanged: (Double) -> Void = { _ in }
    private var onEnded: (Double) -> Void = { _ in }
    private var isTrackingPointer = false
    private var pointerInitialX: CGFloat?
    private var pointerInitialValue: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = KaraokeBoundaryHandleCell()
        sliderType = .linear
        isVertical = false
        isContinuous = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        cell = KaraokeBoundaryHandleCell()
        sliderType = .linear
        isVertical = false
        isContinuous = true
    }

    func configure(
        value: Double,
        range: ClosedRange<Double>,
        timelineWidth: CGFloat,
        cueDuration: Double,
        step: Double,
        label: String,
        identifier: String,
        onChanged: @escaping (Double) -> Void,
        onEnded: @escaping (Double) -> Void
    ) {
        if !isTrackingPointer {
            currentValue = value
            doubleValue = value
        }
        allowedRange = range
        minValue = range.lowerBound
        maxValue = range.upperBound
        self.timelineWidth = max(1, timelineWidth)
        self.cueDuration = max(0.001, cueDuration)
        adjustmentStep = max(0.001, step)
        altIncrementValue = adjustmentStep
        self.onChanged = onChanged
        self.onEnded = onEnded

        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let handleRect = NSRect(
            x: bounds.midX - 1.5,
            y: bounds.midY - 19,
            width: 3,
            height: 38
        )
        let path = NSBezierPath(
            roundedRect: handleRect,
            xRadius: 1.5,
            yRadius: 1.5
        )
        NSColor.white.withAlphaComponent(0.92).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.makeFirstResponder(self)
        isTrackingPointer = true
        pointerInitialX = event.locationInWindow.x
        pointerInitialValue = currentValue
    }

    override func mouseDragged(with event: NSEvent) {
        let adjusted = pointerValue(for: event)
        currentValue = adjusted
        syncAccessibilityValue()
        onChanged(adjusted)
    }

    override func mouseUp(with event: NSEvent) {
        let adjusted = pointerValue(for: event)
        currentValue = adjusted
        isTrackingPointer = false
        pointerInitialX = nil
        pointerInitialValue = nil
        syncAccessibilityValue()
        onEnded(adjusted)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123:
            commit(currentValue - adjustmentStep)
        case 124:
            commit(currentValue + adjustmentStep)
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        commit(currentValue + adjustmentStep)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        commit(currentValue - adjustmentStep)
        return true
    }

    private func commit(_ proposed: Double) {
        let adjusted = clamped(proposed)
        currentValue = adjusted
        syncAccessibilityValue()
        onChanged(adjusted)
        onEnded(adjusted)
    }

    private func clamped(_ proposed: Double) -> Double {
        min(max(proposed, allowedRange.lowerBound), allowedRange.upperBound)
    }

    private func pointerValue(for event: NSEvent) -> Double {
        guard let pointerInitialX, let pointerInitialValue else {
            return currentValue
        }
        let deltaX = event.locationInWindow.x - pointerInitialX
        return clamped(
            pointerInitialValue
                + Double(deltaX / timelineWidth) * cueDuration
        )
    }

    private func syncAccessibilityValue() {
        doubleValue = currentValue
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
}

private final class KaraokeBoundaryHandleCell: NSSliderCell {
    override func drawKnob(_ knobRect: NSRect) {}

    override func drawBar(inside rect: NSRect, flipped: Bool) {}
}
#endif
