//
//  SubtitleProject+SlapEditing.swift
//  Strophe
//
//  Slap-key editing operations
//

import Foundation
import Combine

extension SubtitleProject {
    func handleSlapKeyDown(key: String) {
        if activeSlapKey == key { return }
        syncPlaybackClockFromEngine()
        
        if let currentActiveKey = activeSlapKey, currentActiveKey != key {
            finalizeActiveSlapBlock()
        }
        
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        let activeGroupID = StyleAndGroupStore.shared.activeGroupID
        
        let startTime = snapToFrame(currentTime)
        let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
        let endTime = startTime + minDuration
        
        if let index = items.firstIndex(where: { $0.startTime == nil }) {
            items[index].startTime = startTime
            items[index].endTime = endTime
            items[index].groupID = items[index].groupID ?? activeGroupID
            activeSlapSubtitleID = items[index].id
        } else {
            let newID = UUID()
            let newBlock = SubtitleItem(id: newID, text: String(localized: "draft_subtitle"), startTime: startTime, endTime: endTime, originalIndex: items.count, groupID: activeGroupID)
            items.append(newBlock)
            activeSlapSubtitleID = newID
        }
        
        activeSlapKey = key
        sortItemsStable()
        registerUndo(label: String(localized: "slap_create"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    func handleSlapKeyUp(key: String) {
        if activeSlapKey == key {
            syncPlaybackClockFromEngine()
            finalizeActiveSlapBlock()
            syncPlaybackClockFromEngine()
        }
    }
    
    func finalizeActiveSlapBlock() {
        guard let id = activeSlapSubtitleID else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        
        if let index = items.firstIndex(where: { $0.id == id }) {
            let start = items[index].startTime ?? 0
            let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
            items[index].endTime = snapToFrame(max(start + minDuration, currentTime))
        }
        activeSlapKey = nil
        activeSlapSubtitleID = nil
        
        sortItemsStable()
        registerUndo(label: String(localized: "slap_finalize"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    func updateActiveSlapBlock(currentTime: TimeInterval) {
        guard let id = activeSlapSubtitleID else { return }
        if let index = items.firstIndex(where: { $0.id == id }) {
            let start = items[index].startTime ?? 0
            let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
            items[index].endTime = snapToFrame(max(start + minDuration, currentTime))
        }
    }

    var shouldDeferActiveSlapBlockTimingUpdates: Bool {
        activeSlapSubtitleID != nil
    }
}
