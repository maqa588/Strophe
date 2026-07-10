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
    @State private var previewText: String = "Strophe 活页@样式预览"
    @State private var showsCheckerboard = true
    @State private var showsSafeArea = true
    @State private var previewBackground: PreviewBackground = .neutral
    @State private var isShowingFontPicker = false
    @State private var presetSnapshot: SubgroupStyle?
    
    private var currentFontDisplayName: String {
        if fontName.isEmpty {
            return "系统默认 / PingFang SC"
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
            case .neutral: return "中性"
            case .dark: return "深色"
            case .light: return "浅色"
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
                        Button("取消") { isPresented = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { saveStyle() }
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
                Text("编辑样式")
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
                
                Button("取消") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .tint(Color.stropheText)
                
                Button(action: saveStyle) {
                    Text("保存")
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
                TextField("预览文本", text: $previewText)
                    .textFieldStyle(.roundedBorder)
                    .help("输入用于实时预览的样本文本，不会修改字幕内容")

                Button {
                    resetToPreset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .help("恢复当前 preset 的已保存值")

                Toggle(isOn: $showsCheckerboard) {
                    Image(systemName: "checkerboard.rectangle")
                }
                .toggleStyle(.button)
                .help("显示透明棋盘背景")

                Toggle(isOn: $showsSafeArea) {
                    Image(systemName: "rectangle.dashed")
                }
                .toggleStyle(.button)
                .help("显示 EBU R95 / ITU-R BT.1848 动作安全区（3.5%）与图文安全区（5%）")

                Picker("", selection: $previewBackground) {
                    ForEach(PreviewBackground.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 86)
                .help("切换预览背景亮度")
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
            .help("当前视频分辨率与预览缩放比例")
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
            text: previewText.isEmpty ? "Strophe 活页@样式预览" : previewText,
            style: resolvedPreviewStyle,
            canvasSize: previewVideoSize,
            displayScale: displayScale
        )
    }

    private var propertiesPanel: some View {
        editorSection("样式属性") {
            labeledTextField("名称", text: $name)
            labeledTextField("描述", text: $description)
        }
    }

    private var alignmentPanel: some View {
        editorSection("对齐与位置") {
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
                    Text("位置会同步用于播放器预览和硬字幕烧录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("橙色虚线：动作安全 3.5% · 红色实线：图文安全 5%")
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
        editorSection("边距与变换") {
            compactValueSlider(
                title: "垂直边距",
                value: $marginVerticalPercent,
                range: 0...25,
                step: 0.1,
                valueLabel: String(format: "%.1f%%", marginVerticalPercent),
                help: "设置顶部或底部字幕到画面边缘的距离；5% 对应标准图文安全线"
            )
            compactValueSlider(
                title: "左侧边距",
                value: $marginLeftPercent,
                range: 0...25,
                step: 0.1,
                valueLabel: String(format: "%.1f%%", marginLeftPercent),
                help: "设置左对齐字幕到画面左边缘的距离"
            )
            compactValueSlider(
                title: "右侧边距",
                value: $marginRightPercent,
                range: 0...25,
                step: 0.1,
                valueLabel: String(format: "%.1f%%", marginRightPercent),
                help: "设置右对齐字幕到画面右边缘的距离"
            )
            compactValueSlider(
                title: "横向缩放",
                value: $scaleX,
                range: 0.25...3,
                step: 0.01,
                valueLabel: "\(Int((scaleX * 100).rounded()))%",
                help: "仅在水平方向缩放字幕"
            )
            compactValueSlider(
                title: "纵向缩放",
                value: $scaleY,
                range: 0.25...3,
                step: 0.01,
                valueLabel: "\(Int((scaleY * 100).rounded()))%",
                help: "仅在垂直方向缩放字幕"
            )
            compactValueSlider(
                title: "字间距",
                value: $characterSpacing,
                range: -20...50,
                step: 0.5,
                valueLabel: String(format: "%.1f", characterSpacing),
                help: "调整字符之间的距离"
            )
            compactValueSlider(
                title: "旋转",
                value: $rotationDegrees,
                range: -180...180,
                step: 1,
                valueLabel: "\(Int(rotationDegrees.rounded()))°",
                help: "围绕字幕中心旋转"
            )
        }
    }

    private var typographyPanel: some View {
        editorSection("字体") {
            LabeledContent("字体") {
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
                                    Text("简中").font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1).background(Color.secondary.opacity(0.12)).cornerRadius(3)
                                }
                                if info.categories.contains(.nerd) {
                                    Text("Nerd").font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1).background(Color.indigo.opacity(0.12)).cornerRadius(3)
                                }
                                if info.categories.contains(.monospace) {
                                    Text("等宽").font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1).background(Color.blue.opacity(0.12)).cornerRadius(3)
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
                .help("选择硬字幕渲染字体；导出时会使用同一字体名生成字幕位图")
            }

            LabeledContent("颜色") {
                ColorPicker("", selection: $textColor, supportsOpacity: true)
                    .labelsHidden()
                    .help("设置字幕文字颜色")
            }

            HStack(spacing: 12) {
                Text("字号")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                Slider(value: $fontSize, in: 12...160, step: 1)
                Text("\(Int(fontSize))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
            }

            HStack(spacing: 14) {
                Toggle("B", isOn: $isBold)
                    .toggleStyle(.button)
                    .help("粗体")
                Toggle("I", isOn: $isItalic)
                    .toggleStyle(.button)
                    .help("斜体")
                Toggle(isOn: $isUnderline) {
                    Text("U").underline()
                }
                .toggleStyle(.button)
                .help("下划线")
                Toggle(isOn: $isStrikethrough) {
                    Text("S").strikethrough()
                }
                .toggleStyle(.button)
                .help("删除线")
                Toggle("流光", isOn: $isGlowing)
                    .toggleStyle(.switch)
                    .tint(Color.stropheAccent)
                    .help("为字幕增加发光阴影")
                Spacer()
            }
        }
    }

    private var visualEffectsPanel: some View {
        editorSection("描边、阴影与背景") {
            compactColorSlider(
                title: "描边",
                color: $outlineColor,
                value: $outlineWidth,
                range: 0...16,
                step: 0.5,
                valueLabel: String(format: "%.1f", outlineWidth),
                help: "设置字幕描边颜色和宽度"
            )

            compactColorSlider(
                title: "阴影",
                color: $shadowColor,
                value: $shadowRadius,
                range: 0...24,
                step: 0.5,
                valueLabel: String(format: "%.1f", shadowRadius),
                help: "设置字幕阴影颜色和模糊距离"
            )

            compactColorSlider(
                title: "背景",
                color: $backgroundColor,
                value: $backgroundAlpha,
                range: 0...1,
                step: 0.02,
                valueLabel: "\(Int((backgroundAlpha * 100).rounded()))%",
                help: "设置字幕背景框颜色和不透明度"
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
        .help(help)
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
        .help(help)
    }

    private func resetToPreset() {
        guard let presetSnapshot else { return }
        applyPreset(presetSnapshot)
        previewText = "Strophe 活页@样式预览"
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
