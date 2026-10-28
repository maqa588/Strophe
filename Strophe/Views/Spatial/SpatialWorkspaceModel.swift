//
//  SpatialWorkspaceModel.swift
//  Strophe
//
//  visionOS only: tracks which modules are floating in their own windows so the
//  main editor can replace them with placeholders instead of hosting a second
//  copy of the (single) player surface.
//

#if os(visionOS)
import SwiftUI
import Combine

enum SpatialWindowID {
    static let editor = "editor"
    static let video = "video"
    static let timeline = "timeline"
    static let teleprompter = "teleprompter"
    static let style = "style"
    static let cinema = "cinema"
    static let volume = "volume"
    static let immersive = "immersive"
}

@MainActor
final class SpatialWorkspaceModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case combined
        case review
        case workbench
        case styleLab

        var id: String { rawValue }

        var title: String {
            switch self {
            case .combined: return String(localized: "vp_mode_combined")
            case .review: return String(localized: "vp_mode_review")
            case .workbench: return String(localized: "vp_mode_workbench")
            case .styleLab: return String(localized: "vp_mode_style_lab")
            }
        }

        var systemImage: String {
            switch self {
            case .combined: return "rectangle.on.rectangle"
            case .review: return "play.rectangle"
            case .workbench: return "square.grid.3x3"
            case .styleLab: return "slider.horizontal.3"
            }
        }
    }

    /// The single video surface can only live in one UIKit host at a time.
    @Published var isVideoDetached = false
    @Published var isTimelineDetached = false
    @Published var isTeleprompterOpen = false
    @Published var isCinemaOpen = false
    @Published var isVolumeOpen = false
    @Published var mode: Mode = .combined

    func resetWindowFlags() {
        isVideoDetached = false
        isTimelineDetached = false
        isTeleprompterOpen = false
        isCinemaOpen = false
        isVolumeOpen = false
    }
}
#endif
