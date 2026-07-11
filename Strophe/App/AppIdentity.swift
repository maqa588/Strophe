//
//  AppIdentity.swift
//  Strophe
//
//  Created by Codex on 2026/06/05.
//

import Foundation
import SwiftUI

enum AppIdentity {
    static let displayNameKey = "app_name"

    static var displayName: String {
        String(localized: String.LocalizationValue(displayNameKey))
    }
}
