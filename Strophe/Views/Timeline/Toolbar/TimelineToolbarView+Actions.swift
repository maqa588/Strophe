//
//  TimelineToolbarView.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/17.
//

import SwiftUI
import Combine
#if os(iOS)
import UIKit
#endif

/// 时间轴上方独立的自定义功能工具栏
extension TimelineToolbarView {
    // MARK: - Split / Merge Actions
    
    func handleSplitAction() {
        switch project.validateSplitAtPlayhead() {
        case .ready(let item):
            splitRequest = SplitRequest(item: item, splitTime: project.currentTime)
        case .noBlock:
            splitErrorMessage = String(localized: "no_subtitle_block_at_playhead")
        case .overlapping:
            splitErrorMessage = String(localized: "please_resolve_overlap_issues_before")
        }
    }
    
    func handleMergeAction() {
        if let error = project.mergeSelectedSubtitles() {
            mergeErrorMessage = error
        }
    }}
