//
//  SlapButtonsOverlay.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI

#if os(iOS)
    struct SlapButtonsOverlay: View {
        @ObservedObject var project: SubtitleProject
        @State private var isJPressed = false
        @State private var isKPressed = false

        var body: some View {
            GeometryReader { proxy in
                // Size from the available width instead of the device idiom so
                // iPhone Duo's inner screen and resizable windows behave correctly.
                let isWide = proxy.size.width >= 700

                HStack(spacing: 0) {
                    SlapTouchButton(
                        key: "j", label: String(localized: "slap_j_key"),
                        subtitle: String(localized: "hold_start_release_end"), isPressed: $isJPressed, project: project
                    )
                    .frame(width: isWide ? 180 : nil)
                    .frame(maxWidth: isWide ? nil : .infinity)

                    // Preserve the center ruler and playhead hit area on compact layouts.
                    Spacer(minLength: isWide ? nil : 20)

                    SlapTouchButton(
                        key: "k", label: String(localized: "slap_k_key"),
                        subtitle: String(localized: "hold_start_release_end"), isPressed: $isKPressed, project: project
                    )
                    .frame(width: isWide ? 180 : nil)
                    .frame(maxWidth: isWide ? nil : .infinity)
                }
                .frame(height: 38)
                .padding(.horizontal, isWide ? 24 : 8)
                .allowsHitTesting(true)
            }
            .frame(height: 38)
            .padding(.top, 2)
        }
    }

    struct SlapTouchButton: View {
        let key: String
        let label: String
        let subtitle: String
        @Binding var isPressed: Bool
        @ObservedObject var project: SubtitleProject

        var body: some View {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 8, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.65))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isPressed ? Color.accentColor.opacity(0.85) : Color.black.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isPressed ? Color.white : Color.white.opacity(0.15), lineWidth: 1.0)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            StropheHaptics.perform(.medium)
                            project.handleSlapKeyDown(key: key)
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        StropheHaptics.perform(.light)
                        project.handleSlapKeyUp(key: key)
                    }
            )
        }
    }
#endif
