//
//  StyleCreateSheet.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/31.
//

import SwiftUI

struct StyleCreateSheet: View {
    @Binding var isPresented: Bool
    @Binding var selectedStyleId: UUID?
    
    @ObservedObject var store = StyleAndGroupStore.shared
    
    @State private var name: String = ""
    @State private var description: String = String(localized: "style_description_default_value")
    @State private var colorIndex: Int = 0
    @State private var isGlowing: Bool = false
    
    private let availableColors: [Color] = [
        .white,
        Color(red: 0.0, green: 0.8, blue: 0.9),  // Cyan
        Color(red: 0.5, green: 0.85, blue: 0.0), // Green
        Color(red: 1.0, green: 0.65, blue: 0.0), // Orange
        Color(red: 1.0, green: 0.1, blue: 0.6),  // Pink
        Color(red: 0.6, green: 0.3, blue: 0.9)   // Purple
    ]
    
    var body: some View {
        #if os(macOS)
        mainContent
            .frame(width: 440, height: 420)
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
                        Button("create") { createStyle() }
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
                Text("new_style")
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
                VStack(spacing: 20) {
                    // Section 1: Properties
                    VStack(alignment: .leading, spacing: 14) {
                        Text("style_properties")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.stropheText)
                        
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                Text("name")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .leading)
                                
                                TextField("style_name", text: $name)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.subheadline)
                            }
                            
                            HStack(spacing: 12) {
                                Text("description")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .leading)
                                
                                TextField("style_description_eg_58_pt", text: $description)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.subheadline)
                            }
                            
                            Toggle(isOn: $isGlowing) {
                                Text("glow_special_effect_glow")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .toggleStyle(.switch)
                            .tint(Color.stropheAccent)
                            .padding(.top, 4)
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
                    
                    // Section 2: Color Picker
                    VStack(alignment: .leading, spacing: 14) {
                        Text("representative_color")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.stropheText)
                        
                        HStack(spacing: 16) {
                            ForEach(0..<availableColors.count, id: \.self) { i in
                                ZStack {
                                    Circle()
                                        .fill(availableColors[i])
                                        .frame(width: 32, height: 32)
                                        .overlay(
                                            Circle()
                                                .stroke(availableColors[i] == .white ? Color.secondary.opacity(0.5) : Color.clear, lineWidth: 1)
                                        )
                                        .shadow(color: availableColors[i].opacity(0.3), radius: 4, x: 0, y: 2)
                                    
                                    if colorIndex == i {
                                        Circle()
                                            .strokeBorder(Color.stropheAccent, lineWidth: 2.5)
                                            .frame(width: 40, height: 40)
                                    }
                                }
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                        colorIndex = i
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 6)
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
                
                Button(action: createStyle) {
                    Text("create")
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
            if name.isEmpty {
                name = String(localized: "style_default_name_pattern \(store.styles.count + 1)")
            }
        }
    }
    
    private func createStyle() {
        let newStyle = SubgroupStyle(
            name: name.isEmpty ? "Style" : name,
            description: description,
            color: availableColors[colorIndex],
            isGlowing: isGlowing
        )
        store.styles.append(newStyle)
        selectedStyleId = newStyle.id
        isPresented = false
    }
}
