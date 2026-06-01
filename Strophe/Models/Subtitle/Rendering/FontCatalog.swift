//
//  FontCatalog.swift
//  Strophe
//
//  Created by Antigravity on 2026/06/01.
//

import Foundation
import CoreText
import SwiftUI
import Combine
#if os(macOS)
import AppKit
#elseif os(iOS) || os(tvOS) || os(watchOS)
import UIKit
#endif

public enum FontFilterCategory: String, CaseIterable, Identifiable, Codable {
    case all = "全部"
    case favorite = "收藏"
    case recent = "最近"
    case sc = "简中"
    case tc = "繁中"
    case ja = "日文"
    case ko = "韩文"
    case emoji = "Emoji"
    case nerd = "Nerd Font"
    case monospace = "等宽"
    case serif = "衬线"
    case sans = "无衬线"

    public var id: String { rawValue }
    
    public var iconName: String {
        switch self {
        case .all: return "textformat"
        case .favorite: return "star.fill"
        case .recent: return "clock"
        case .sc: return "character.sutton"
        case .tc: return "character.traditional.chinese"
        case .ja: return "character.japanese"
        case .ko: return "character.korean"
        case .emoji: return "face.smiling"
        case .nerd: return "terminal"
        case .monospace: return "chevron.left.forwardslash.chevron.right"
        case .serif: return "serif"
        case .sans: return "character"
        }
    }
}

public struct FontInfo: Identifiable, Hashable {
    public let id: String // Family Name used for CTFont / NSFont / UIFont loading
    public let familyName: String
    public let localizedFamilyName: String
    public var categories: Set<FontFilterCategory>
    public var isFavorite: Bool
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public static func == (lhs: FontInfo, rhs: FontInfo) -> Bool {
        lhs.id == rhs.id
    }
    
    // Choose correct sample text based on supported languages
    public var sampleText: String {
        if categories.contains(.emoji) && id.contains("Emoji") {
            return "😀😂🥺🚀🌏⭐️❤️"
        }
        if categories.contains(.nerd) {
            return " Swift  GitHub  Terminal"
        }
        if categories.contains(.sc) && categories.contains(.tc) {
            return "你好世界 繁體中文 Hello"
        }
        if categories.contains(.sc) {
            return "你好世界 Hello World"
        }
        if categories.contains(.tc) {
            return "繁體字 語言測試 Hello"
        }
        if categories.contains(.ja) {
            return "こんにちは世界 Hello"
        }
        if categories.contains(.ko) {
            return "안녕하세요 Hello World"
        }
        return "The quick brown fox 123"
    }
}

public class FontCatalog: ObservableObject {
    public static let shared = FontCatalog()
    
    @Published public var fonts: [FontInfo] = []
    @Published public var isLoading: Bool = true
    
    private let favoritesKey = "strophe_favorite_fonts_v2"
    private let recentsKey = "strophe_recent_fonts_v2"
    
    private var favoriteFontNames: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
            return Set(arr)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: favoritesKey)
            objectWillChange.send()
        }
    }
    
    private var recentFontNames: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        }
        set {
            UserDefaults.standard.set(newValue, forKey: recentsKey)
            objectWillChange.send()
        }
    }
    
    private init() {
        loadCatalog()
    }
    
    public func loadCatalog() {
        self.isLoading = true
        
        let favorites = self.favoriteFontNames
        let recents = self.recentFontNames
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Local thread-safe character checking helper functions
            func checkSimplifiedChinese(_ cfCharacterSet: CFCharacterSet) -> Bool {
                let chars = ["你", "们", "这", "国", "简"]
                let matchCount = chars.filter { char in
                    guard let scalar = char.unicodeScalars.first else { return false }
                    return CFCharacterSetIsLongCharacterMember(cfCharacterSet, scalar.value)
                }.count
                return matchCount >= 3
            }

            func checkTraditionalChinese(_ cfCharacterSet: CFCharacterSet) -> Bool {
                let chars = ["漢", "繁", "國", "體", "選"]
                let matchCount = chars.filter { char in
                    guard let scalar = char.unicodeScalars.first else { return false }
                    return CFCharacterSetIsLongCharacterMember(cfCharacterSet, scalar.value)
                }.count
                return matchCount >= 3
            }

            func checkJapanese(_ cfCharacterSet: CFCharacterSet) -> Bool {
                let chars = ["あ", "の", "な", "ア", "ン"]
                let matchCount = chars.filter { char in
                    guard let scalar = char.unicodeScalars.first else { return false }
                    return CFCharacterSetIsLongCharacterMember(cfCharacterSet, scalar.value)
                }.count
                return matchCount >= 3
            }

            func checkKorean(_ cfCharacterSet: CFCharacterSet) -> Bool {
                let chars = ["한", "글", "아", "요", "네"]
                let matchCount = chars.filter { char in
                    guard let scalar = char.unicodeScalars.first else { return false }
                    return CFCharacterSetIsLongCharacterMember(cfCharacterSet, scalar.value)
                }.count
                return matchCount >= 3
            }

            func checkEmoji(_ cfCharacterSet: CFCharacterSet) -> Bool {
                let chars = ["😀", "🚀", "❤️"]
                return chars.contains { char in
                    guard let scalar = char.unicodeScalars.first else { return false }
                    return CFCharacterSetIsLongCharacterMember(cfCharacterSet, scalar.value)
                }
            }

            func checkNerdFont(_ cfCharacterSet: CFCharacterSet) -> Bool {
                let nerdFontPUACodes: [UInt32] = [
                    0xE0B0, // Powerline Arrow left
                    0xF113, // GitHub logo in NF
                    0xF300  // Linux logo in NF
                ]
                return nerdFontPUACodes.contains { code in
                    CFCharacterSetIsLongCharacterMember(cfCharacterSet, code)
                }
            }

            // Get all system font family names
            var familyNames: [String] = []
            #if os(macOS)
            familyNames = NSFontManager.shared.availableFontFamilies
            #elseif os(iOS)
            familyNames = UIFont.familyNames.sorted()
            #else
            familyNames = ["PingFang SC", "Helvetica Neue", "Arial"]
            #endif
            
            var loadedFonts: [FontInfo] = []
            
            for family in familyNames {
                // CTFontCreateWithName returns non-optional
                let ctFont = CTFontCreateWithName(family as CFString, 12.0, nil)
                
                // Get localized family name
                let localizedFamilyName = (CTFontCopyLocalizedName(ctFont, kCTFontFamilyNameKey, nil) as String?) ?? family
                
                // CTFontCopyCharacterSet returns non-optional
                let cfCharacterSet = CTFontCopyCharacterSet(ctFont)
                
                // Categories set
                var categories: Set<FontFilterCategory> = [.all]
                
                // 1. Language checks (using local thread-safe helper functions)
                if checkSimplifiedChinese(cfCharacterSet) {
                    categories.insert(.sc)
                }
                if checkTraditionalChinese(cfCharacterSet) {
                    categories.insert(.tc)
                }
                if checkJapanese(cfCharacterSet) {
                    categories.insert(.ja)
                }
                if checkKorean(cfCharacterSet) {
                    categories.insert(.ko)
                }
                if checkEmoji(cfCharacterSet) {
                    categories.insert(.emoji)
                }
                if checkNerdFont(cfCharacterSet) {
                    categories.insert(.nerd)
                }
                
                // 2. Symbolic traits (monospace, serif, sans)
                let traits = CTFontGetSymbolicTraits(ctFont)
                
                // Monospace check
                let isMono = traits.contains(.traitMonoSpace) 
                    || (traits.rawValue & (1 << 10) != 0) 
                    || family.localizedCaseInsensitiveContains("mono") 
                    || family.localizedCaseInsensitiveContains("consolas") 
                    || family.localizedCaseInsensitiveContains("courier") 
                    || family.localizedCaseInsensitiveContains("menlo")
                
                if isMono {
                    categories.insert(.monospace)
                }
                
                // Serif vs Sans check
                let isSerif = (traits.rawValue & (1 << 6) != 0) 
                    || family.localizedCaseInsensitiveContains("serif") 
                    || family.localizedCaseInsensitiveContains("song") 
                    || family.localizedCaseInsensitiveContains("ming") 
                    || family.localizedCaseInsensitiveContains("mincho")
                
                let isSans = (traits.rawValue & (1 << 7) != 0) 
                    || family.localizedCaseInsensitiveContains("sans") 
                    || family.localizedCaseInsensitiveContains("hei") 
                    || family.localizedCaseInsensitiveContains("gothic") 
                    || family.localizedCaseInsensitiveContains("pingfang") 
                    || family.localizedCaseInsensitiveContains("helvetica") 
                    || family.localizedCaseInsensitiveContains("arial")
                
                if isSerif {
                    categories.insert(.serif)
                } else if isSans {
                    categories.insert(.sans)
                } else {
                    // Fallback heuristics: default CJK fonts are mostly Sans unless they are Song/Ming
                    if categories.contains(.sc) || categories.contains(.tc) || categories.contains(.ja) || categories.contains(.ko) {
                        if family.localizedCaseInsensitiveContains("song") || family.localizedCaseInsensitiveContains("ming") || family.localizedCaseInsensitiveContains("mincho") {
                            categories.insert(.serif)
                        } else {
                            categories.insert(.sans)
                        }
                    } else {
                        categories.insert(.sans) // default fallback
                    }
                }
                
                if favorites.contains(family) {
                    categories.insert(.favorite)
                }
                if recents.contains(family) {
                    categories.insert(.recent)
                }
                
                let fontInfo = FontInfo(
                    id: family,
                    familyName: family,
                    localizedFamilyName: localizedFamilyName,
                    categories: categories,
                    isFavorite: favorites.contains(family)
                )
                
                loadedFonts.append(fontInfo)
            }
            
            // Re-order so that favorite and recent fonts are easy to find, or keep alphabetical order
            loadedFonts.sort { $0.localizedFamilyName.localizedCompare($1.localizedFamilyName) == .orderedAscending }
            
            DispatchQueue.main.async {
                self.fonts = loadedFonts
                self.isLoading = false
            }
        }
    }
    
    // Toggle favorite
    public func toggleFavorite(for family: String) {
        var favorites = self.favoriteFontNames
        if favorites.contains(family) {
            favorites.remove(family)
        } else {
            favorites.insert(family)
        }
        self.favoriteFontNames = favorites
        
        // Update model array in memory
        if let idx = fonts.firstIndex(where: { $0.id == family }) {
            var updated = fonts[idx]
            updated.isFavorite = favorites.contains(family)
            if updated.isFavorite {
                updated.categories.insert(.favorite)
            } else {
                updated.categories.remove(.favorite)
            }
            fonts[idx] = updated
        }
    }
    
    // Add to recent list
    public func addToRecent(family: String) {
        var recents = self.recentFontNames
        recents.removeAll { $0 == family }
        recents.insert(family, at: 0)
        if recents.count > 12 {
            recents = Array(recents.prefix(12))
        }
        self.recentFontNames = recents
        
        // Update in memory
        for idx in 0..<fonts.count {
            if fonts[idx].id == family {
                fonts[idx].categories.insert(.recent)
            } else if !recents.contains(fonts[idx].id) {
                fonts[idx].categories.remove(.recent)
            }
        }
    }
}
