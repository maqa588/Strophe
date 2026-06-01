//
//  SubGroupCreateSheet.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/31.
//

import SwiftUI

struct SubGroupCreateSheet: View {
    @Binding var isPresented: Bool
    
    @ObservedObject var store = StyleAndGroupStore.shared
    
    @State private var name: String = ""
    @State private var subName: String = "默认分组"
    @State private var role: SubtitleGroupRole = .normal
    @State private var selectedStyleName: String = ""
    @State private var selectedColorIndex: Int = 0
    
    private let availableColors: [Color] = [
        Color(red: 1.0, green: 0.65, blue: 0.0), // Orange
        Color(red: 0.5, green: 0.85, blue: 0.0), // Green
        Color(red: 0.0, green: 0.8, blue: 0.9),  // Cyan
        Color(red: 0.0, green: 0.5, blue: 1.0),  // Blue
        Color(red: 0.6, green: 0.3, blue: 0.9),  // Purple
        Color(red: 1.0, green: 0.1, blue: 0.6),  // Pink
        Color(red: 1.0, green: 0.3, blue: 0.1),  // Coral
        Color(red: 0.1, green: 0.8, blue: 0.4)   // Emerald
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
                        Button("取消") { isPresented = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("创建") { createGroup() }
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
                Text("新建分组")
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
                        Text("分组信息")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.stropheText)
                        
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                Text("名称")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 50, alignment: .leading)
                                
                                TextField("分组名称", text: $name)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.subheadline)
                            }
                            
                            HStack(spacing: 12) {
                                Text("子标题")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 50, alignment: .leading)
                                
                                TextField("子标题，例如：默认分组", text: $subName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.subheadline)
                            }

                            LabeledContent("角色") {
                                Picker("", selection: $role) {
                                    ForEach(SubtitleGroupRole.allCases) { role in
                                        Text(role.title).tag(role)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                            }

                            LabeledContent("样式") {
                                Picker("", selection: $selectedStyleName) {
                                    ForEach(store.styles) { style in
                                        Text(style.name).tag(style.name)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                            }
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
                        Text("代表颜色")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.stropheText)
                        
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                            ForEach(0..<availableColors.count, id: \.self) { i in
                                ZStack {
                                    Circle()
                                        .fill(availableColors[i])
                                        .frame(width: 32, height: 32)
                                        .shadow(color: availableColors[i].opacity(0.3), radius: 4, x: 0, y: 2)
                                    
                                    if selectedColorIndex == i {
                                        Circle()
                                            .strokeBorder(Color.stropheAccent, lineWidth: 2.5)
                                            .frame(width: 40, height: 40)
                                    }
                                }
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                        selectedColorIndex = i
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
                
                Button("取消") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .tint(Color.stropheText)
                
                Button(action: createGroup) {
                    Text("创建")
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
                name = "组 \(store.groups.count + 1)"
            }
            if selectedStyleName.isEmpty {
                selectedStyleName = store.styles.first?.name ?? "Default"
            }
            selectedColorIndex = store.groups.count % availableColors.count
        }
    }
    
    private func createGroup() {
        let defaultStyle = selectedStyleName.isEmpty ? (store.styles.first?.name ?? "Default") : selectedStyleName
        let newGroup = SubGroupItem(
            name: name.isEmpty ? "未命名组" : name,
            subName: subName,
            role: role,
            color: availableColors[selectedColorIndex],
            isActive: store.groups.isEmpty,
            style: defaultStyle,
            isOverlayEnabled: true,
            isFlagged: role == .secondaryLanguage || role == .translatedDraft,
            exportPolicy: role == .metadata ? .referenceOnly : .includeInAllExports,
            sortOrder: store.groups.count
        )
        store.groups.append(newGroup)
        isPresented = false
    }
}
