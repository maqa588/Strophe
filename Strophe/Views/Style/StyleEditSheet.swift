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
    
    @State var name: String = ""
    @State var description: String = ""
    @State var textColor: Color = .white
    @State var fontName: String = ""
    @State var fontSize: Double = 58
    @State var isBold: Bool = true
    @State var isItalic: Bool = false
    @State var isUnderline: Bool = false
    @State var isStrikethrough: Bool = false
    @State var outlineColor: Color = .black
    @State var outlineWidth: Double = 4
    @State var shadowColor: Color = .black
    @State var shadowRadius: Double = 5
    @State var backgroundColor: Color = .black
    @State var backgroundAlpha: Double = 0
    @State var isGlowing: Bool = false
    @State var alignment: SubtitleStyle.Alignment = .bottomCenter
    @State var marginLeftPercent: Double = 5
    @State var marginRightPercent: Double = 5
    @State var marginVerticalPercent: Double = 5
    @State var scaleX: Double = 1
    @State var scaleY: Double = 1
    @State var characterSpacing: Double = 0
    @State var rotationDegrees: Double = 0
    @State var previewText: String = String(localized: "style_preview_text_default")
    @State var showsCheckerboard = true
    @State var showsSafeArea = true
    @State var previewBackground: PreviewBackground = .neutral
    @State var isShowingFontPicker = false
    @State var presetSnapshot: SubgroupStyle?
    
    var currentFontDisplayName: String {
        if fontName.isEmpty {
            return "system_default_pingfang_sc"
        }
        if let info = FontCatalog.shared.fonts.first(where: { $0.id == fontName }) {
            return info.localizedFamilyName
        }
        return fontName
    }
    
    var currentFontInfo: FontInfo? {
        FontCatalog.shared.fonts.first(where: { $0.id == fontName })
    }

    var previewVideoSize: CGSize {
        guard project.videoSize.width > 0, project.videoSize.height > 0 else {
            return CGSize(width: 1920, height: 1080)
        }
        return project.videoSize
    }

    enum PreviewBackground: String, CaseIterable, Identifiable {
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

}
