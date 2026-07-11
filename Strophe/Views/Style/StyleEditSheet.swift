//
//  StyleEditSheet.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/31.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct StyleEditSheet: View {
    @Binding var isPresented: Bool
    @Binding var selectedStyleId: UUID?
    @ObservedObject var project: SubtitleProject
    
    @ObservedObject var store = StyleAndGroupStore.shared
    
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var textColor: Color = .white
    @State private var fontName: String = ""
    @State private var fontSize: Double = 58
    @State private var isBold: Bool = true
    @State private var isItalic: Bool = false
    @State private var isUnderline: Bool = false
    @State private var isStrikethrough: Bool = false
    @State private var outlineColor: Color = .black
    @State private var outlineWidth: Double = 4
    @State private var shadowColor: Color = .black
    @State private var shadowRadius: Double = 5
    @State private var backgroundColor: Color = .black
    @State private var backgroundAlpha: Double = 0
    @State private var isGlowing: Bool = false
    @State private var alignment: SubtitleStyle.Alignment = .bottomCenter
    @State private var marginLeftPercent: Double = 5
    @State private var marginRightPercent: Double = 5
    @State private var marginVerticalPercent: Double = 5
    @State private var scaleX: Double = 1
    @State private var scaleY: Double = 1
    @State private var characterSpacing: Double = 0
    @State private var rotationDegrees: Double = 0
    @State private var previewText: String = String(localized: "style_preview_text_default")
    @State private var showsCheckerboard = true
    @State private var showsSafeArea = true
    @State private var previewBackground: PreviewBackground = .neutral
    @State private var isShowingFontPicker = false
    @State private var presetSnapshot: SubgroupStyle?
    
    private var currentFontDisplayName: String {
        if fontName.isEmpty {
            return "system_default_pingfang_sc"
        }
        if let info = FontCatalog.shared.fonts.first(where: { $0.id == fontName }) {
            return info.localizedFamilyName
        }
        return fontName
    }
    
    private var currentFontInfo: FontInfo? {
        FontCatalog.shared.fonts.first(where: { $0.id == fontName })
    }

    private var previewVideoSize: CGSize {
        guard project.videoSize.width > 0, project.videoSize.height > 0 else {
            return CGSize(width: 1920, height: 1080)
        }
        return project.videoSize
    }

    private enum PreviewBackground: String, CaseIterable, Identifiable {
        case neutral
        case dark
        case light

        var id: String { rawValue }

        var title: String {
            switch self {
            case .neutral: return "background_neutral"
            case .dark: return "background_dark"
            case .light: return "background_light"
            }
        }

        var color: Color {
            switch self {
            case .neutral: return Color(red: 0.55, green: 0.57, blue: 0.62)
            case .dark: return Color(red: 0.06, green: 0.07, blue: 0.08)
            case .light: return Color(red: 0.86, green: 0.87, blue: 0.9)
            }
        }
    }
    
    var body: some View {
        #if os(macOS)
        mainContent
            .frame(width: 760, height: 700)
            .background(VisualEffectView(material: .sheet, blendingMode: .behindWindow))
        #else
        NavigationStack {
            mainContent
                .background(Color.stropheBackground)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("cancel") { isPresented = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("save") { saveStyle() }
                            .fontWeight(.bold)
                            .disabled(name.isEmpty)
                    }
                }
        }
        #endif
    }
    
    private var mainContent: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header for macOS
            HStack {
                Text("edit_style")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.stropheText)
                
                Spacer()
                
                Button(action: { isPresented = false }) {
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
            #endif
            
            ScrollView {
                VStack(spacing: 16) {
                    previewPanel
                    propertiesPanel
                    alignmentPanel
                    layoutTransformPanel
                    typographyPanel
                    visualEffectsPanel
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            
            #if os(macOS)
            Divider()
                .background(Color.stropheBorder)
            
            // Bottom Actions for macOS
            HStack {
                Spacer()
                
                Button("cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .tint(Color.stropheText)
                
                Button(action: saveStyle) {
                    Text("save")
                        .fontWeight(.bold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stropheAccent)
                .disabled(name.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            #endif
        }
        .onAppear {
            if let id = selectedStyleId,
               let style = store.styles.first(where: { $0.id == id }) {
                presetSnapshot = style
                applyPreset(style)
            }
        }
    }

    private var previewPanel: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                let displayScale = proxy.size.height / previewVideoSize.height
                let placementRect = SubtitlePlacementMetrics.placementRect(
                    for: previewVideoSize,
                    style: resolvedPreviewStyle
                )

                ZStack {
                    if showsCheckerboard {
                        CheckerboardPattern()
                            .opacity(0.42)
                    }

                    previewBackground.color.opacity(showsCheckerboard ? 0.55 : 1)

                    if showsSafeArea {
                        Rectangle()
                            .stroke(
                                Color.orange.opacity(0.78),
                                style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                            )
                            .padding(.horizontal, proxy.size.width * SubtitlePlacementMetrics.actionSafeInsetRatio)
                            .padding(.vertical, proxy.size.height * SubtitlePlacementMetrics.actionSafeInsetRatio)

                        Rectangle()
                            .stroke(Color.stropheAccent.opacity(0.82), lineWidth: 1)
                            .padding(.horizontal, proxy.size.width * SubtitlePlacementMetrics.graphicsSafeInsetRatio)
                            .padding(.vertical, proxy.size.height * SubtitlePlacementMetrics.graphicsSafeInsetRatio)
                    }

                    stylePreviewText(displayScale: displayScale)
                        .frame(
                            width: placementRect.width * displayScale,
                            height: placementRect.height * displayScale,
                            alignment: alignment.swiftUIAlignment
                        )
                        .position(
                            x: placementRect.midX * displayScale,
                            y: placementRect.midY * displayScale
                        )

                    previewResolutionBadge(displayScale: displayScale)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .aspectRatio(previewVideoSize.width / previewVideoSize.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: 320)

            HStack(spacing: 10) {
                TextField("preview_text", text: $previewText)
                    .textFieldStyle(.roundedBorder)
                    .help("enter_sample_text_for_live")

                Button {
                    resetToPreset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .help(String(localized: "restore_current_preset_saved_values"))

                Toggle(isOn: $showsCheckerboard) {
                    Image(systemName: "checkerboard.rectangle")
                }
                .toggleStyle(.button)
                .help(String(localized: "show_transparent_checkerboard_background"))

                Toggle(isOn: $showsSafeArea) {
                    Image(systemName: "rectangle.dashed")
                }
                .toggleStyle(.button)
                .help(String(localized: "show_safe_areas_explanation"))

                Picker("", selection: $previewBackground) {
                    ForEach(PreviewBackground.allCases) { mode in
                        Text(LocalizedStringKey(mode.title)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 86)
                .help(String(localized: "toggle_preview_background_brightness"))
            }
        }
    }

    private func previewResolutionBadge(displayScale: CGFloat) -> some View {
        let width = Int(previewVideoSize.width.rounded())
        let height = Int(previewVideoSize.height.rounded())
        let percentage = displayScale * 100

        return Text("\(width) × \(height)  ·  \(percentage, specifier: "%.1f")%")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.48), in: Capsule())
            .help("current_video_resolution_preview_scale")
    }

    private var resolvedPreviewStyle: ResolvedSubtitleStyle {
        ResolvedSubtitleStyle(
            name: name,
            fontName: fontName.isEmpty ? nil : fontName,
            fontSize: fontSize,
            textColor: textColor.resolvedRGBA,
            outlineColor: outlineColor.resolvedRGBA,
            outlineWidth: outlineWidth,
            shadowColor: shadowColor.resolvedRGBA,
            shadowRadius: shadowRadius,
            backgroundColor: backgroundAlpha > 0 ? backgroundColor.resolvedRGBA.withAlpha(backgroundAlpha) : nil,
            isBold: isBold,
            isItalic: isItalic,
            isUnderline: isUnderline,
            isStrikethrough: isStrikethrough,
            isGlowing: isGlowing,
            alignment: alignment,
            marginLeftPercent: marginLeftPercent,
            marginRightPercent: marginRightPercent,
            marginVerticalPercent: marginVerticalPercent,
            scaleX: scaleX,
            scaleY: scaleY,
            characterSpacing: characterSpacing,
            rotationDegrees: rotationDegrees
        )
    }

    private func stylePreviewText(displayScale: CGFloat) -> some View {
        HardSubtitleBitmapView(
            text: previewText.isEmpty ? String(localized: "style_preview_text_default") : previewText,
            style: resolvedPreviewStyle,
            canvasSize: previewVideoSize,
            displayScale: displayScale
        )
    }

    private var propertiesPanel: some View {
        editorSection("style_properties") {
            labeledTextField("name", text: $name)
            labeledTextField("description", text: $description)
        }
    }

    private var alignmentPanel: some View {
        editorSection("style_alignment_and_position") {
            HStack(alignment: .center, spacing: 18) {
                VStack(spacing: 3) {
                    ForEach(alignmentRows, id: \.self) { row in
                        HStack(spacing: 3) {
                            ForEach(row) { option in
                                alignmentButton(option)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(alignment.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.stropheText)
                    Text("position_sync_explanation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("safe_area_legend")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
    }

    private var alignmentRows: [[SubtitleStyle.Alignment]] {
        [
            [.topLeft, .topCenter, .topRight],
            [.middleLeft, .middleCenter, .middleRight],
            [.bottomLeft, .bottomCenter, .bottomRight]
        ]
    }

    private func alignmentButton(_ option: SubtitleStyle.Alignment) -> some View {
        Button {
            alignment = option
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(alignment == option ? Color.stropheAccent.opacity(0.22) : Color.stropheSecondaryBackground.opacity(0.65))
                .overlay {
                    Circle()
                        .fill(alignment == option ? Color.stropheAccent : Color.secondary)
                        .frame(width: 7, height: 7)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: option.swiftUIAlignment)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(alignment == option ? Color.stropheAccent : Color.stropheBorder, lineWidth: alignment == option ? 1.5 : 1)
                }
                .frame(width: 42, height: 30)
        }
        .buttonStyle(.plain)
        .help(option.title)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(alignment == option ? .isSelected : [])
    }

    private var layoutTransformPanel: some View {
        editorSection("style_margins_and_transforms") {
            compactValueSlider(
                title: "style_vertical_margin",
                value: $marginVerticalPercent,
                range: 0...25,
                step: 0.1,
                valueLabel: String(format: "%.1f%%", marginVerticalPercent),
                help: "style_vertical_margin_help"
            )
            compactValueSlider(
                title: "style_left_margin",
                value: $marginLeftPercent,
                range: 0...25,
                step: 0.1,
                valueLabel: String(format: "%.1f%%", marginLeftPercent),
                help: "style_left_margin_help"
            )
            compactValueSlider(
                title: "style_right_margin",
                value: $marginRightPercent,
                range: 0...25,
                step: 0.1,
                valueLabel: String(format: "%.1f%%", marginRightPercent),
                help: "style_right_margin_help"
            )
            compactValueSlider(
                title: "style_horizontal_scale",
                value: $scaleX,
                range: 0.25...3,
                step: 0.01,
                valueLabel: "\(Int((scaleX * 100).rounded()))%",
                help: "style_horizontal_scale_help"
            )
            compactValueSlider(
                title: "style_vertical_scale",
                value: $scaleY,
                range: 0.25...3,
                step: 0.01,
                valueLabel: "\(Int((scaleY * 100).rounded()))%",
                help: "style_vertical_scale_help"
            )
            compactValueSlider(
                title: "style_character_spacing",
                value: $characterSpacing,
                range: -20...50,
                step: 0.5,
                valueLabel: String(format: "%.1f", characterSpacing),
                help: "style_character_spacing_help"
            )
            compactValueSlider(
                title: "style_rotation",
                value: $rotationDegrees,
                range: -180...180,
                step: 1,
                valueLabel: "\(Int(rotationDegrees.rounded()))°",
                help: "style_rotation_help"
            )
        }
    }

    private var typographyPanel: some View {
        editorSection("font") {
            LabeledContent("font") {
                Button {
                    isShowingFontPicker = true
                } label: {
                    HStack {
                        Text(currentFontDisplayName)
                            .foregroundStyle(Color.stropheText)
                            .font(.subheadline)
                        
                        if let info = currentFontInfo {
                            HStack(spacing: 4) {
                                if info.categories.contains(.sc) {
                                    Text("simplified_chinese").font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1).background(Color.secondary.opacity(0.12)).cornerRadius(3)
                                }
                                if info.categories.contains(.nerd) {
                                    Text("tab_nerd").font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1).background(Color.indigo.opacity(0.12)).cornerRadius(3)
                                }
                                if info.categories.contains(.monospace) {
                                    Text("monospace").font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1).background(Color.blue.opacity(0.12)).cornerRadius(3)
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.stropheSecondaryBackground.opacity(0.4))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.stropheBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .popover(isPresented: $isShowingFontPicker, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
                    FontPickerView(selectedFontName: $fontName) { _ in
                        isShowingFontPicker = false
                    }
                }
                .help("select_hard_subtitle_rendering_font")
            }

            LabeledContent("color") {
                ColorPicker("", selection: $textColor, supportsOpacity: true)
                    .labelsHidden()
                    .help("set_subtitle_text_color")
            }

            HStack(spacing: 12) {
                Text("font_size")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                Slider(value: $fontSize, in: 12...160, step: 1)
                Text("\(Int(fontSize))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
            }

            HStack(spacing: 14) {
                Toggle("btn_bold", isOn: $isBold)
                    .toggleStyle(.button)
                    .help(String(localized: "bold"))
                Toggle("btn_italic", isOn: $isItalic)
                    .toggleStyle(.button)
                    .help(String(localized: "italic"))
                Toggle(isOn: $isUnderline) {
                    Text("btn_underline").underline()
                }
                .toggleStyle(.button)
                .help(String(localized: "underline"))
                Toggle(isOn: $isStrikethrough) {
                    Text("btn_strikethrough").strikethrough()
                }
                .toggleStyle(.button)
                .help(String(localized: "strikethrough"))
                Toggle("glow_special_effect_glow", isOn: $isGlowing)
                    .toggleStyle(.switch)
                    .tint(Color.stropheAccent)
                    .help(String(localized: "add_glowing_shadow_for_subtitles"))
                Spacer()
            }
        }
    }

    private var visualEffectsPanel: some View {
        editorSection("style_border_shadow_background") {
            compactColorSlider(
                title: "style_stroke",
                color: $outlineColor,
                value: $outlineWidth,
                range: 0...16,
                step: 0.5,
                valueLabel: String(format: "%.1f", outlineWidth),
                help: "style_stroke_help"
            )

            compactColorSlider(
                title: "style_shadow",
                color: $shadowColor,
                value: $shadowRadius,
                range: 0...24,
                step: 0.5,
                valueLabel: String(format: "%.1f", shadowRadius),
                help: "style_shadow_help"
            )

            compactColorSlider(
                title: "style_background",
                color: $backgroundColor,
                value: $backgroundAlpha,
                range: 0...1,
                step: 0.02,
                valueLabel: "\(Int((backgroundAlpha * 100).rounded()))%",
                help: "style_background_help"
            )
        }
    }

    private func editorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(Color.stropheText)

            VStack(spacing: 12) {
                content()
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

    private func labeledTextField(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            TextField(placeholder.isEmpty ? label : placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
        }
    }

    private func compactColorSlider(
        title: String,
        color: Binding<Color>,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueLabel: String,
        help: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            ColorPicker("", selection: color, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 44)

            Slider(value: value, in: range, step: step)
            Text(valueLabel)
                .font(.caption.monospacedDigit())
                .frame(width: 48, alignment: .trailing)
        }
        .help(String(localized: String.LocalizationValue(help)))
    }

    private func compactValueSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueLabel: String,
        help: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            Slider(value: value, in: range, step: step)
            Text(valueLabel)
                .font(.caption.monospacedDigit())
                .frame(width: 58, alignment: .trailing)
        }
        .help(String(localized: String.LocalizationValue(help)))
    }

    private func resetToPreset() {
        guard let presetSnapshot else { return }
        applyPreset(presetSnapshot)
        previewText = String(localized: "style_preview_text_default")
    }

    private func applyPreset(_ style: SubgroupStyle) {
        name = style.name
        description = style.description
        textColor = style.color
        fontName = style.fontName ?? ""
        fontSize = style.fontSize
        isBold = style.isBold
        isItalic = style.isItalic
        isUnderline = style.isUnderline
        isStrikethrough = style.isStrikethrough
        outlineColor = style.outlineColor
        outlineWidth = style.outlineWidth
        shadowColor = style.shadowColor
        shadowRadius = style.shadowRadius
        backgroundColor = style.backgroundColor
        backgroundAlpha = style.backgroundAlpha
        isGlowing = style.isGlowing
        alignment = style.alignment
        marginLeftPercent = style.marginLeftPercent
        marginRightPercent = style.marginRightPercent
        marginVerticalPercent = style.marginVerticalPercent
        scaleX = style.scaleX
        scaleY = style.scaleY
        characterSpacing = style.characterSpacing
        rotationDegrees = style.rotationDegrees
    }
    
    private func saveStyle() {
        if let id = selectedStyleId,
           let index = store.styles.firstIndex(where: { $0.id == id }) {
            store.styles[index].name = name.isEmpty ? "Style" : name
            store.styles[index].description = description
            store.styles[index].color = textColor
            store.styles[index].fontName = fontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : fontName
            store.styles[index].fontSize = fontSize
            store.styles[index].isBold = isBold
            store.styles[index].isItalic = isItalic
            store.styles[index].isUnderline = isUnderline
            store.styles[index].isStrikethrough = isStrikethrough
            store.styles[index].outlineColor = outlineColor
            store.styles[index].outlineWidth = outlineWidth
            store.styles[index].shadowColor = shadowColor
            store.styles[index].shadowRadius = shadowRadius
            store.styles[index].backgroundColor = backgroundColor
            store.styles[index].backgroundAlpha = backgroundAlpha
            store.styles[index].isGlowing = isGlowing
            store.styles[index].alignment = alignment
            store.styles[index].marginLeftPercent = marginLeftPercent
            store.styles[index].marginRightPercent = marginRightPercent
            store.styles[index].marginVerticalPercent = marginVerticalPercent
            store.styles[index].scaleX = scaleX
            store.styles[index].scaleY = scaleY
            store.styles[index].characterSpacing = characterSpacing
            store.styles[index].rotationDegrees = rotationDegrees
        }
        isPresented = false
    }
}

private struct CheckerboardPattern: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 18
            let columns = Int(ceil(size.width / tile))
            let rows = Int(ceil(size.height / tile))

            for row in 0..<rows {
                for column in 0..<columns {
                    let isDark = (row + column).isMultiple(of: 2)
                    let rect = CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)
                    context.fill(Path(rect), with: .color(isDark ? Color.gray.opacity(0.35) : Color.gray.opacity(0.2)))
                }
            }
        }
    }
}
