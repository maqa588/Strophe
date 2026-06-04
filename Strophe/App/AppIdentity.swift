//
//  AppIdentity.swift
//  Strophe
//
//  Created by Codex on 2026/06/05.
//

import Foundation
import SwiftUI

enum AppIdentity {
    #if STROPHE_LITE
    static let displayNameKey = "Strophe Lite"
    #else
    static let displayNameKey = "Strophe"
    #endif

    static var displayName: String {
        String(localized: String.LocalizationValue(displayNameKey))
    }
}
