//
//  StropheTabBar.swift
//  Strophe
//
//  iOS 26+ / macOS 26+ Liquid Glass floating navigation.
//  The modern path avoids opaque background blocks and lets the control hover
//  directly above the surrounding content.
//

import SwiftUI

struct StropheTabBar: View {
    @Binding var selectedTab: StropheTab
    var tabs: [StropheTab] = StropheTab.allCases

    @Namespace private var selectionNamespace
    @State private var containerWidth: CGFloat = 0
    @State private var dragLocationX: CGFloat?
    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var selectedIndex: Int {
        guard !tabs.isEmpty else { return 0 }
        return tabs.firstIndex(of: selectedTab) ?? 0
    }

    private var liveIndex: Int {
        guard let dragLocationX, containerWidth > 0, !tabs.isEmpty else {
            return selectedIndex
        }

        let itemWidth = containerWidth / CGFloat(tabs.count)
        let rawIndex = Int(dragLocationX / itemWidth)
        return max(0, min(tabs.count - 1, rawIndex))
    }

    private var barHeight: CGFloat {
        isDesktop ? 50 : 56
    }

    private var buttonHeight: CGFloat {
        isDesktop ? 40 : 46
    }

    private var tabBarSpring: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .interactiveSpring(response: 0.3, dampingFraction: 0.72)
    }

    #if os(macOS) || os(visionOS)
    let isDesktop = true
    #else
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var isDesktop: Bool { horizontalSizeClass == .regular }
    #endif

    var body: some View {
        if #available(anyAppleOS 26.0, *) {
            advancedLiquidGlassTabBar
        } else {
            ordinaryTabBar
        }
    }

    @available(anyAppleOS 26.0, *)
    private var advancedLiquidGlassTabBar: some View {
        GlassEffectContainer(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    movingSelectionThumb

                    HStack(spacing: 4) {
                        ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                            liquidGlassTabButton(for: tab, index: index)
                        }
                    }
                    .padding(5)
                }
                .onAppear {
                    containerWidth = proxy.size.width
                }
                .stropheOnChange(of: proxy.size.width) { newWidth in
                    containerWidth = newWidth
                }
                .stropheGlassCapsule(interactive: true, reduceTransparency: reduceTransparency)
                .gesture(tabDragGesture)
            }
            .frame(height: barHeight)
        }
        .frame(maxWidth: isDesktop ? 360 : 430)
        .padding(.horizontal, isDesktop ? 20 : 16)
        .padding(.bottom, isDesktop ? 20 : 12)
        .stropheOnChange(of: selectedTab) { newTab in
            if tabs.contains(newTab) {
                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.72)) {
                    dragLocationX = nil
                    isDragging = false
                }
            }
        }
    }

    @available(anyAppleOS 26.0, *)
    private var movingSelectionThumb: some View {
        let outerPadding: CGFloat = 5
        let spacing: CGFloat = 4
        let count = CGFloat(tabs.count)
        let availableWidth = max(containerWidth - outerPadding * 2 - spacing * CGFloat(max(tabs.count - 1, 0)), 0)
        let itemWidth = count > 0 ? availableWidth / count : 0
        let restingX = outerPadding + CGFloat(selectedIndex) * (itemWidth + spacing)
        let liveX: CGFloat = {
            guard let dragLocationX else { return restingX }
            let halfWidth = itemWidth / 2
            let minX = outerPadding
            let maxX = max(outerPadding, containerWidth - outerPadding - itemWidth)
            return min(max(dragLocationX - halfWidth, minX), maxX)
        }()

        return HStack(spacing: 0) {
            Color.clear
                .frame(width: liveX)

            Capsule()
                .fill(.clear)
                .frame(width: itemWidth, height: buttonHeight)
                .scaleEffect(isDragging ? 1.04 : 1.0)
                .stropheGlassCapsule(interactive: true, reduceTransparency: reduceTransparency)
                .glassEffectID("selectionThumb", in: selectionNamespace)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(tabBarSpring, value: selectedIndex)
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.16, dampingFraction: 0.82), value: isDragging)
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.14, dampingFraction: 0.86), value: dragLocationX)
    }

    @available(anyAppleOS 26.0, *)
    @ViewBuilder
    private func liquidGlassTabButton(for tab: StropheTab, index: Int) -> some View {
        let isActive = isTabVisuallyActive(index)

        Button {
            selectTab(tab, at: index)
        } label: {
            Image(systemName: tab.systemImage)
                .font(.system(size: isDesktop ? 18 : 20, weight: isActive ? .semibold : .regular))
                .symbolVariant(isActive ? .fill : .none)
                .symbolEffect(.bounce, value: isActive)
                .environment(\.locale, Locale(identifier: "en"))
                .frame(maxWidth: .infinity)
                .frame(height: buttonHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.stropheAccent : Color.secondary)
        .scaleEffect(isActive ? 1.07 : 1.0)
        .animation(tabBarSpring, value: isActive)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isActive ? Text("selected") : Text(""))
        #if os(macOS)
        .help(tab.title)
        #endif
    }

    private func isTabVisuallyActive(_ index: Int) -> Bool {
        isDragging ? liveIndex == index : selectedIndex == index
    }

    @available(anyAppleOS 26.0, *)
    private func selectTab(_ tab: StropheTab, at index: Int) {
        withAnimation(tabBarSpring) {
            selectedTab = tab
            dragLocationX = nil
            isDragging = false
        }
    }

    @available(anyAppleOS 26.0, *)
    private var tabDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleLiveDrag(value)
            }
            .onEnded { value in
                commitLiveDrag(value)
            }
    }

    private func handleLiveDrag(_ value: DragGesture.Value) {
        guard containerWidth > 0, !tabs.isEmpty else { return }
        isDragging = true
        dragLocationX = value.location.x
    }

    private func commitLiveDrag(_ value: DragGesture.Value) {
        guard containerWidth > 0, !tabs.isEmpty else {
            isDragging = false
            dragLocationX = nil
            return
        }

        let tabWidth = containerWidth / CGFloat(tabs.count)
        let index = Int(value.location.x / tabWidth)
        let clampedIndex = max(0, min(tabs.count - 1, index))

        withAnimation(tabBarSpring) {
            selectedTab = tabs[clampedIndex]
            dragLocationX = nil
            isDragging = false
        }
    }

    private var ordinaryTabBar: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 18, weight: selectedTab == tab ? .semibold : .regular))
                            .environment(\.locale, Locale(identifier: "en"))
                    }
                    .foregroundStyle(selectedTab == tab ? Color.stropheAccent : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityValue(selectedTab == tab ? Text("selected") : Text(""))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

private extension View {
    @available(anyAppleOS 26.0, *)
    @ViewBuilder
    func stropheGlassCapsule(interactive: Bool, reduceTransparency: Bool) -> some View {
        if reduceTransparency {
            self.background(.regularMaterial, in: .capsule)
        } else if interactive {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self.glassEffect(.regular, in: .capsule)
        }
    }
}
