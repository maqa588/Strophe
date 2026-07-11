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
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        
        HStack(spacing: 0) {
            // J Button
            SlapTouchButton(key: "j", label: String(localized: "slap_j_key"), subtitle: String(localized: "hold_start_release_end"), isPressed: $isJPressed, project: project)
                .frame(width: isPad ? 180 : nil)
                .frame(maxWidth: isPad ? nil : .infinity)
            
            // Middle Gap to keep playhead and center ruler times perfectly visible!
            Spacer(minLength: isPad ? nil : 20)
            
            // K Button
            SlapTouchButton(key: "k", label: String(localized: "slap_k_key"), subtitle: String(localized: "hold_start_release_end"), isPressed: $isKPressed, project: project)
                .frame(width: isPad ? 180 : nil)
                .frame(maxWidth: isPad ? nil : .infinity)
        }
        .frame(height: 38) // Exquisitely slim height, sits elegantly over the ruler and completely clears the subtitles below!
        .padding(.horizontal, isPad ? 24 : 8)
        .padding(.top, 2)
        .allowsHitTesting(true)
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
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        project.handleSlapKeyDown(key: key)
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                    project.handleSlapKeyUp(key: key)
                }
        )
    }
}
#endif
