//
//  StropheSidebarContainer.swift
//  Strophe
//

import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

struct StropheSidebarContainer: View {
    @ObservedObject var project: SubtitleProject
    @Binding var selectedTab: StropheTab
    @Binding var settingsPath: [SettingsRoute]

    private var usesLiquidGlassNavigation: Bool {
        if #available(anyAppleOS 26.0, *) { true } else { false }
    }

    var body: some View {
        #if os(macOS)
            sidebarContent
                .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
                .hideSidebarSystemNavigationBar()
        #elseif os(visionOS)
            // visionOS provides its own window glass; keep the sidebar free of
            // opaque backgrounds so the system material shows through.
            sidebarContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .hideSidebarSystemNavigationBar()
        #else
            if #available(anyAppleOS 26.0, *) {
                sidebarContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
                    .hideSidebarSystemNavigationBar()
            } else {
                sidebarContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .hideSidebarSystemNavigationBar()
            }
        #endif
    }

    @ViewBuilder
    private var sidebarContent: some View {
        Group {
            #if os(visionOS)
            // Top-level navigation lives in the window's native TabView, so the
            // custom bottom tab bar is redundant here.
            sidebarPrimaryContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            #else
            if usesLiquidGlassNavigation {
                ZStack(alignment: .bottom) {
                    sidebarPrimaryContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    StropheTabBar(selectedTab: $selectedTab, tabs: StropheTab.wideTabs)
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
            } else {
                VStack(spacing: 0) {
                    sidebarPrimaryContent
                        .frame(maxHeight: .infinity)

                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color.stropheBorder)

                    StropheTabBar(selectedTab: $selectedTab, tabs: StropheTab.wideTabs)
                        .padding(.top, 12)
                }
            }
            #endif
        }
        // System toolbar: on macOS this is auto-paired with the sidebar toggle button.
        // On iPadOS, the navbar is now visible (we only hide its background via
        // .toolbarBackground(.hidden)), so .toolbar items render correctly here too.
        .toolbar {
            StropheSidebarToolbar(selectedTab: selectedTab)
        }
    }

    @ViewBuilder
    private var sidebarPrimaryContent: some View {
        Group {
            switch selectedTab {
            case .editor, .scriptList:
                ScriptListView(project: project)
            case .styleManager:
                StylePlaceholderView(project: project)
            case .subGroup:
                SubGroupPlaceholderView(project: project)
            case .settings:
                SettingsPlaceholderView(settingsPath: $settingsPath)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Cross-platform navigation bar helper

extension View {
    @ViewBuilder
    fileprivate func hideSidebarSystemNavigationBar() -> some View {
        #if os(iOS)
            // Clear system navigation title (our custom ZStack header is the only title).
            // Keep .toolbarBackground(.hidden) so the bar's layout footprint remains
            // stable and .toolbar items (plus button, sidebar toggle) render correctly.
            self
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
        #else
            self.navigationTitle("")
        #endif
    }
}
