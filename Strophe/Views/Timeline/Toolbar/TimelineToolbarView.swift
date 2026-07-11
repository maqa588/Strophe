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
struct TimelineToolbarView: View {
    let project: SubtitleProject
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    
    // Dynamic available width state to achieve fluid cross-platform responsiveness
    @State var availableWidth: CGFloat = 800
    
    var isCompact: Bool {
        return availableWidth < 720
    }

    var isVeryCompact: Bool {
        return availableWidth < 430
    }
    
    // Local state variables for layout and rendering, keeping body evaluations isolated
    @State var targetSpeed: Double = 1.0
    @State var showSoftSubtitles: Bool = false
    @State var showHardSubtitles: Bool = false
    @State var editingMode: TimelineEditingMode = .selection
    @State var videoURL: URL? = nil
    @State var isAudioOnly: Bool = false
    @State var videoFrameRate: Double = 30.0
    @State var waveformData: WaveformData? = nil
    @State var playbackRate: Double = 0.0
    @State var isEditingText: Bool = false
    
    @State var showSoftSubtitlesTip = false
    @State var showHardSubtitlesTip = false
    @State var showSelectionTip = false
    @State var showCreationTip = false
    @State var showSplitTip = false
    @State var showMergeTip = false
    
    // 用于 macOS 鼠标延时悬浮（0.5秒）的取消型 Task 实例
    @State var softSubtitlesHoverTask: Task<Void, Never>? = nil
    @State var hardSubtitlesHoverTask: Task<Void, Never>? = nil
    @State var selectionHoverTask: Task<Void, Never>? = nil
    @State var creationHoverTask: Task<Void, Never>? = nil
    @State var splitHoverTask: Task<Void, Never>? = nil
    @State var mergeHoverTask: Task<Void, Never>? = nil
    
    // 切分/合并操作状态
    @State var splitRequest: SplitRequest? = nil
    @State var mergeErrorMessage: String? = nil
    @State var splitErrorMessage: String? = nil
    
    var body: some View {
        VStack(spacing: isCompact ? 8 : 0) {
            if isCompact {
                // Compact two-row layout for iPhone & narrow Mac windows
                if videoURL != nil {
                    HStack {
                        #if !os(watchOS)
                        AirPlayRoutePicker()
                            .frame(width: 24, height: 24)
                        #endif
                        
                        Spacer()
                        
                        playbackControls
                        
                        Spacer()
                        
                        // Balance empty spacer to center the playback controls perfectly
                        Spacer()
                            .frame(width: 24)
                    }
                    .padding(.bottom, 2)
                }
                
                HStack(spacing: isVeryCompact ? 6 : 10) {
                    mediaInfoSection
                    Spacer(minLength: isVeryCompact ? 4 : 8)
                    editingModeControls
                }
            } else {
                // Regular one-row layout for Mac and iPad
                HStack {
                    HStack(spacing: 8) {
                        #if !os(watchOS)
                        if videoURL != nil {
                            AirPlayRoutePicker()
                                .frame(width: 24, height: 24)
                        }
                        #endif
                        mediaInfoSection
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    
                    Spacer()
                    
                    if videoURL != nil {
                        playbackControls
                    }
                    
                    Spacer()
                    
                    editingModeControls
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        availableWidth = geo.size.width
                    }
                    .stropheOnChange(of: geo.size.width) { newWidth in
                        availableWidth = newWidth
                    }
            }
        )
        .onAppear {
            syncStateFromProject()
        }
        .onReceive(project.objectWillChange) { _ in
            // Dispatch to next runloop to read post-change published values
            DispatchQueue.main.async {
                syncStateFromProject()
            }
        }
        .sheet(item: $splitRequest) { request in
            SubtitleSplitView(
                item: request.item,
                splitTime: request.splitTime,
                project: project,
                onDismiss: { splitRequest = nil }
            )
        }
        .alert(String(localized: "无法切分"), isPresented: Binding(
            get: { splitErrorMessage != nil },
            set: { if !$0 { splitErrorMessage = nil } }
        )) {
            Button(String(localized: "确定"), role: .cancel) { splitErrorMessage = nil }
        } message: {
            Text(splitErrorMessage ?? "")
        }
        .alert(String(localized: "无法合并"), isPresented: Binding(
            get: { mergeErrorMessage != nil },
            set: { if !$0 { mergeErrorMessage = nil } }
        )) {
            Button(String(localized: "确定"), role: .cancel) { mergeErrorMessage = nil }
        } message: {
            Text(mergeErrorMessage ?? "")
        }
    }
    
    func syncStateFromProject() {
        if targetSpeed != project.targetSpeed {
            targetSpeed = project.targetSpeed
        }
        if showSoftSubtitles != project.showSoftSubtitles {
            showSoftSubtitles = project.showSoftSubtitles
        }
        if showHardSubtitles != project.showHardSubtitles {
            showHardSubtitles = project.showHardSubtitles
        }
        if editingMode != project.editingMode {
            editingMode = project.editingMode
        }
        if videoURL != project.videoURL {
            videoURL = project.videoURL
        }
        if isAudioOnly != project.isAudioOnly {
            isAudioOnly = project.isAudioOnly
        }
        if videoFrameRate != project.videoFrameRate {
            videoFrameRate = project.videoFrameRate
        }
        if waveformData !== project.waveformData {
            waveformData = project.waveformData
        }
        if playbackRate != project.playbackRate {
            playbackRate = project.playbackRate
        }
        if isEditingText != project.isEditingText {
            isEditingText = project.isEditingText
        }
    }
}
