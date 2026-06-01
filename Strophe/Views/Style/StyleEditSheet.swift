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
    
    @ObservedObject var store = StyleAndGroupStore.shared
    
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var textColor: Color = .white
    @State private var fontName: String = ""
    @State private var fontSize: Double = 58
    @State private var isBold: Bool = true
    @State private var isItalic: Bool = false
    @State private var outlineColor: Color = .black
    @State private var outlineWidth: Double = 4
    @State private var shadowColor: Color = .black
    @State private var shadowRadius: Double = 5
    @State private var backgroundColor: Color = .black
    @State private var backgroundAlpha: Double = 0
    @State private var isGlowing: Bool = false
    @State private var previewText: String = "Strophe 活页@样式预览"
    @State private var showsCheckerboard = true
    @State private var showsSafeArea = true
    @State private var previewBackground: PreviewBackground = .neutral
    @State private var isShowingFontPicker = false
    
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
                name = style.name
                description = style.description
                textColor = style.color
                fontName = style.fontName ?? ""
                fontSize = style.fontSize
                isBold = style.isBold
                isItalic = style.isItalic
                outlineColor = style.outlineColor
                outlineWidth = style.outlineWidth
                shadowColor = style.shadowColor
                shadowRadius = style.shadowRadius
                backgroundColor = style.backgroundColor
                backgroundAlpha = style.backgroundAlpha
                isGlowing = style.isGlowing
            }
        }
    }

    private var previewPanel: some View {
        VStack(spacing: 10) {
            ZStack {
                if showsCheckerboard {
                    CheckerboardPattern()
                        .opacity(0.42)
                }

                previewBackground.color.opacity(showsCheckerboard ? 0.55 : 1)

                if showsSafeArea {
                    Rectangle()
                        .stroke(Color.stropheAccent.opacity(0.82), lineWidth: 1)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 18)
                }

                stylePreviewText
                    .padding(.horizontal, 36)
            }
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 10) {
                TextField("预览文本", text: $previewText)
                    .textFieldStyle(.roundedBorder)
                    .help("输入用于实时预览的样本文本，不会修改字幕内容")

                Button {
                    previewText = "Strophe 活页@样式预览"
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .help("恢复默认预览文本")

                Toggle(isOn: $showsCheckerboard) {
                    Image(systemName: "checkerboard.rectangle")
                }
                .toggleStyle(.button)
                .help("显示透明棋盘背景")

                Toggle(isOn: $showsSafeArea) {
                    Image(systemName: "rectangle.dashed")
                }
                .toggleStyle(.button)
                .help("显示视频安全框")

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

    private var stylePreviewText: some View {
        let previewStyle = ResolvedSubtitleStyle(
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
            isGlowing: isGlowing
        )

        return HardSubtitleStylePreviewText(text: previewText.isEmpty ? "Strophe 活页@样式预览" : previewText, style: previewStyle, scale: 0.74)
    }

    private var propertiesPanel: some View {
        editorSection("样式属性") {
            labeledTextField("名称", text: $name)
            labeledTextField("描述", text: $description)
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
            store.styles[index].outlineColor = outlineColor
            store.styles[index].outlineWidth = outlineWidth
            store.styles[index].shadowColor = shadowColor
            store.styles[index].shadowRadius = shadowRadius
            store.styles[index].backgroundColor = backgroundColor
            store.styles[index].backgroundAlpha = backgroundAlpha
            store.styles[index].isGlowing = isGlowing
        }
        isPresented = false
    }
}

private struct HardSubtitleStylePreviewText: View {
    let text: String
    let style: ResolvedSubtitleStyle
    let scale: CGFloat

    var body: some View {
        let fontSize = max(12, style.fontSize * scale)
        ZStack {
            if style.outlineWidth > 0 {
                outlineText(fontSize: fontSize)
            }
            Text(text)
                .font(previewFont(size: fontSize))
                .fontWeight(style.isBold ? .bold : .semibold)
                .italic(style.isItalic)
                .foregroundStyle(style.textColor.color)
                .shadow(color: style.shadowColor.color, radius: max(0, style.shadowRadius * scale), x: 0, y: max(0, style.shadowRadius * 0.35 * scale))
        }
        .padding(.horizontal, style.backgroundColor == nil ? 0 : 16)
        .padding(.vertical, style.backgroundColor == nil ? 0 : 8)
        .background {
            if let background = style.backgroundColor {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background.color)
            }
        }
        .glow(color: style.isGlowing ? style.textColor.color.opacity(0.45) : .clear, radius: style.isGlowing ? 10 : 0)
    }

    private func previewFont(size: CGFloat) -> Font {
        if let fontName = style.fontName, !fontName.isEmpty {
            return .custom(fontName, size: size)
        }
        return .system(size: size, weight: style.isBold ? .bold : .semibold, design: .rounded)
    }

    private func outlineText(fontSize: CGFloat) -> some View {
        let radius = max(1, style.outlineWidth * scale)
        return ZStack {
            Text(text).offset(x: -radius, y: 0)
            Text(text).offset(x: radius, y: 0)
            Text(text).offset(x: 0, y: -radius)
            Text(text).offset(x: 0, y: radius)
            Text(text).offset(x: -radius * 0.72, y: -radius * 0.72)
            Text(text).offset(x: radius * 0.72, y: -radius * 0.72)
            Text(text).offset(x: -radius * 0.72, y: radius * 0.72)
            Text(text).offset(x: radius * 0.72, y: radius * 0.72)
        }
        .font(previewFont(size: fontSize))
        .fontWeight(style.isBold ? .bold : .semibold)
        .italic(style.isItalic)
        .foregroundStyle(style.outlineColor.color)
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

