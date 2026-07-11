//
//  FontPickerView.swift
//  Strophe
//
//  Created by Antigravity on 2026/06/01.
//

import SwiftUI

public struct FontPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog = FontCatalog.shared
    
    @Binding var selectedFontName: String
    var onSelect: (String) -> Void
    
    @State private var searchText = ""
    @State private var selectedCategory: FontFilterCategory = .all
    @State private var hoveredFontId: String? = nil
    
    public init(selectedFontName: Binding<String>, onSelect: @escaping (String) -> Void) {
        self._selectedFontName = selectedFontName
        self.onSelect = onSelect
    }
    
    private var filteredFonts: [FontInfo] {
        catalog.fonts.filter { font in
            // 1. Search Query filter
            if !searchText.isEmpty {
                let matchSearch = font.familyName.localizedCaseInsensitiveContains(searchText)
                    || font.localizedFamilyName.localizedCaseInsensitiveContains(searchText)
                if !matchSearch { return false }
            }
            
            // 2. Category filter
            if selectedCategory == .all {
                return true
            } else {
                return font.categories.contains(selectedCategory)
            }
        }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header (macOS title or simple banner)
            HStack {
                Text("select_font")
                    .font(.headline)
                    .foregroundStyle(Color.stropheText)
                Spacer()
                Text("fonts_count_available \(filteredFonts.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            // Search Box
            searchBar
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            
            // Categories Segment
            categoryFilterBar
                .padding(.bottom, 10)
            
            Divider()
                .background(Color.stropheBorder)
            
            // Content
            if catalog.isLoading {
                loadingView
            } else if filteredFonts.isEmpty {
                emptyView
            } else {
                fontListView
            }
        }
        .frame(width: 390, height: 500)
        .background(Color.stropheBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.footnote)
            
            TextField("search_fonts_placeholder", text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .disableAutocorrection(true)
            
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.stropheSecondaryBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.stropheBorder, lineWidth: 1)
        )
    }
    
    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(FontFilterCategory.allCases) { category in
                    let isSelected = selectedCategory == category
                    Button {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                            selectedCategory = category
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: category.iconName)
                                .font(.caption2)
                            Text(category.rawValue)
                                .font(.caption)
                                .fontWeight(isSelected ? .semibold : .regular)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            isSelected ? Color.stropheAccent : Color.stropheSecondaryBackground.opacity(0.5)
                        )
                        .foregroundStyle(isSelected ? .white : Color.stropheText.opacity(0.85))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? Color.clear : Color.stropheBorder, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
    
    private var fontListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredFonts, id: \.id) { font in
                    let isSelected = selectedFontName == font.id
                    FontRow(
                        font: font,
                        isSelected: isSelected,
                        isHovered: hoveredFontId == font.id,
                        onHover: { hovering in
                            if hovering {
                                hoveredFontId = font.id
                            } else if hoveredFontId == font.id {
                                hoveredFontId = nil
                            }
                        },
                        onSelect: {
                            selectedFontName = font.id
                            catalog.addToRecent(family: font.id)
                            onSelect(font.id)
                        },
                        onFavorite: {
                            catalog.toggleFavorite(for: font.id)
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .tint(Color.stropheAccent)
            Text("scanning_system_fonts")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
    
    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "textformat.abc.dottedblock")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("no_matching_fonts_found")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct FontRow: View {
    let font: FontInfo
    let isSelected: Bool
    let isHovered: Bool
    var onHover: (Bool) -> Void
    var onSelect: () -> Void
    var onFavorite: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    // Font Family Name (Localized / Primary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(font.localizedFamilyName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.stropheText)
                            
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.stropheAccent)
                            }
                        }
                        
                        // English name as subtitle if different
                        if font.familyName != font.localizedFamilyName {
                            Text(font.familyName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    // Tag Pills
                    HStack(spacing: 4) {
                        if font.categories.contains(.sc) {
                            tagBadge("simplified_chinese")
                        }
                        if font.categories.contains(.tc) {
                            tagBadge("traditional_chinese")
                        }
                        if font.categories.contains(.ja) {
                            tagBadge("japanese")
                        }
                        if font.categories.contains(.ko) {
                            tagBadge("korean")
                        }
                        if font.categories.contains(.nerd) {
                            tagBadge("tab_nerd", color: .indigo)
                        }
                        if font.categories.contains(.emoji) && font.id.contains("Emoji") {
                            tagBadge("Emoji", color: .orange)
                        }
                        if font.categories.contains(.monospace) {
                            tagBadge("monospace", color: .blue)
                        }
                    }
                    
                    // Favorite Star
                    Button(action: onFavorite) {
                        Image(systemName: font.isFavorite ? "star.fill" : "star")
                            .font(.subheadline)
                            .foregroundStyle(font.isFavorite ? .orange : Color.stropheText.opacity(0.3))
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                
                // Real Font Preview Text
                Text(font.sampleText)
                    .font(.custom(font.id, size: 14))
                    .foregroundStyle(Color.stropheText.opacity(0.75))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.stropheBackground.opacity(0.5))
                    .cornerRadius(4)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.stropheAccent.opacity(0.08) : (isHovered ? Color.stropheSecondaryBackground.opacity(0.6) : Color.stropheSecondaryBackground.opacity(0.2)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.stropheAccent.opacity(0.35) : (isHovered ? Color.stropheBorder : Color.clear), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
    }
    
    private func tagBadge(_ text: String, color: Color = .gray) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
