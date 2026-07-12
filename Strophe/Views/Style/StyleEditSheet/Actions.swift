//
//  StyleEditSheet+Actions.swift
//  Strophe
//
//  Created by Antigravity on 2026/07/12.
//

import SwiftUI

extension StyleEditSheet {

    func resetToPreset() {
        guard let presetSnapshot else { return }
        applyPreset(presetSnapshot)
        previewText = String(localized: "style_preview_text_default")
    }

    func applyPreset(_ style: SubgroupStyle) {
        name = style.name
        description = style.description
        textColor = style.color
        fontName = style.fontName ?? ""
        fontSize = style.fontSize
        isBold = style.isBold
        isItalic = style.isItalic
        isUnderline = style.isUnderline
        isStrikethrough = style.isStrikethrough
        outlineColor = style.outlineColor
        outlineWidth = style.outlineWidth
        shadowColor = style.shadowColor
        shadowRadius = style.shadowRadius
        backgroundColor = style.backgroundColor
        backgroundAlpha = style.backgroundAlpha
        isGlowing = style.isGlowing
        alignment = style.alignment
        marginLeftPercent = style.marginLeftPercent
        marginRightPercent = style.marginRightPercent
        marginVerticalPercent = style.marginVerticalPercent
        scaleX = style.scaleX
        scaleY = style.scaleY
        characterSpacing = style.characterSpacing
        rotationDegrees = style.rotationDegrees
    }

    func saveStyle() {
        if let id = selectedStyleId,
           let index = store.styles.firstIndex(where: { $0.id == id }) {
            store.styles[index].name = name.isEmpty ? "Style" : name
            store.styles[index].description = description
            store.styles[index].color = textColor
            store.styles[index].fontName = fontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : fontName
            store.styles[index].fontSize = fontSize
            store.styles[index].isBold = isBold
            store.styles[index].isItalic = isItalic
            store.styles[index].isUnderline = isUnderline
            store.styles[index].isStrikethrough = isStrikethrough
            store.styles[index].outlineColor = outlineColor
            store.styles[index].outlineWidth = outlineWidth
            store.styles[index].shadowColor = shadowColor
            store.styles[index].shadowRadius = shadowRadius
            store.styles[index].backgroundColor = backgroundColor
            store.styles[index].backgroundAlpha = backgroundAlpha
            store.styles[index].isGlowing = isGlowing
            store.styles[index].alignment = alignment
            store.styles[index].marginLeftPercent = marginLeftPercent
            store.styles[index].marginRightPercent = marginRightPercent
            store.styles[index].marginVerticalPercent = marginVerticalPercent
            store.styles[index].scaleX = scaleX
            store.styles[index].scaleY = scaleY
            store.styles[index].characterSpacing = characterSpacing
            store.styles[index].rotationDegrees = rotationDegrees
        }
        isPresented = false
    }
}
