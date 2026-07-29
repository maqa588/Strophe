//
//  StropheLocalization.swift
//  Strophe
//

import Foundation

/// Resolves resources from the application bundle even when Strophe code is
/// hosted by XCTest or another tool whose `Bundle.main` is not the app.
nonisolated private final class StropheLocalizationBundleLocator {}

nonisolated func stropheLocalizedString(
    _ key: String,
    comment: String = ""
) -> String {
    NSLocalizedString(
        key,
        bundle: Bundle(for: StropheLocalizationBundleLocator.self),
        comment: comment
    )
}
