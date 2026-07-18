//
//  StyleEditSheet+Panels.swift
//  Strophe
//
//  Created by Antigravity on 2026/07/12.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension StyleEditSheet {

    var previewPanel: some View {
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

    func previewResolutionBadge(displayScale: CGFloat) -> some View {
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

    var resolvedPreviewStyle: ResolvedSubtitleStyle {
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

    func stylePreviewText(displayScale: CGFloat) -> some View {
        HardSubtitleBitmapView(
            text: previewText.isEmpty ? String(localized: "style_preview_text_default") : previewText,
            style: resolvedPreviewStyle,
            canvasSize: previewVideoSize,
            displayScale: displayScale
        )
    }

    var propertiesPanel: some View {
        editorSection("style_properties") {
            labeledTextField("name", text: $name)
            labeledTextField("description", text: $description)
        }
    }

    var alignmentPanel: some View {
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

    var alignmentRows: [[SubtitleStyle.Alignment]] {
        [
            [.topLeft, .topCenter, .topRight],
            [.middleLeft, .middleCenter, .middleRight],
            [.bottomLeft, .bottomCenter, .bottomRight]
        ]
    }

    func alignmentButton(_ option: SubtitleStyle.Alignment) -> some View {
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

    var layoutTransformPanel: some View {
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

    var typographyPanel: some View {
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

    var visualEffectsPanel: some View {
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

    func editorSection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
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

    func labeledTextField(_ label: LocalizedStringKey, text: Binding<String>, placeholder: LocalizedStringKey? = nil) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            TextField(placeholder ?? label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
        }
    }

    func compactColorSlider(
        title: LocalizedStringKey,
        color: Binding<Color>,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueLabel: String,
        help: LocalizedStringKey
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
        .help(help)
    }

    func compactValueSlider(
        title: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueLabel: String,
        help: LocalizedStringKey
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
        .help(help)
    }
}

struct CheckerboardPattern: View {
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
