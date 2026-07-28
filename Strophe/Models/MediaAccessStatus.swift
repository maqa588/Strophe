//
//  MediaAccessStatus.swift
//  Strophe
//

import Foundation

enum MediaAccessState: String, Codable, Equatable, Sendable {
    case none
    case resolving
    case ready
    case missing
    case permissionDenied
    case unreadable
    case unsupported
}

struct MediaAccessStatus: Codable, Equatable, Sendable {
    var state: MediaAccessState
    var requestedURL: URL?
    var resolvedURL: URL?
    var usesSecurityScope: Bool
    var technicalMessage: String?

    static let none = MediaAccessStatus(
        state: .none,
        requestedURL: nil,
        resolvedURL: nil,
        usesSecurityScope: false,
        technicalMessage: nil
    )

    static func ready(
        requestedURL: URL,
        resolvedURL: URL,
        usesSecurityScope: Bool
    ) -> MediaAccessStatus {
        MediaAccessStatus(
            state: .ready,
            requestedURL: requestedURL,
            resolvedURL: resolvedURL,
            usesSecurityScope: usesSecurityScope,
            technicalMessage: nil
        )
    }

    var canRead: Bool {
        state == .ready && resolvedURL != nil
    }
}
