//
//  StyleEditSheet.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/31.
//

import SwiftUI

struct StyleEditSheet: View {
    @Binding var isPresented: Bool
    @Binding var selectedStyleId: UUID?
    
    @ObservedObject var store = StyleAndGroupStore.shared
    
    @State private var name: String = ""
    @State private var description: String = ""
    
    var body: some View {
        #if os(macOS)
        mainContent
            .frame(width: 440, height: 260)
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
                VStack(spacing: 20) {
                    // Section 1: Properties
                    VStack(alignment: .leading, spacing: 14) {
                        Text("样式属性")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.stropheText)
                        
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                Text("名称")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .leading)
                                
                                TextField("样式名称", text: $name)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.subheadline)
                            }
                            
                            HStack(spacing: 12) {
                                Text("描述")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .leading)
                                
                                TextField("样式描述", text: $description)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.subheadline)
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
            }
        }
    }
    
    private func saveStyle() {
        if let id = selectedStyleId,
           let index = store.styles.firstIndex(where: { $0.id == id }) {
            store.styles[index].name = name.isEmpty ? "Style" : name
            store.styles[index].description = description
        }
        isPresented = false
    }
}
