//
//  FFmpegEngine+DisplayLink.swift
//  Strophe
//
//  Created by Antigravity on 2026/07/12.
//

import SwiftUI
import AVFoundation
import Combine
import MetalKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension FFmpegEngine {

    // MARK: - Display Link

    func startDisplayLink() {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            if displayLinkStorage == nil {
                let link = playerView.displayLink(
                    target: self,
                    selector: #selector(displayLinkFired(_:))
                )
                link.add(to: .main, forMode: .common)
                displayLinkStorage = link
            }
            updateDisplayLinkPreferredFrameRate()
            (displayLinkStorage as? CADisplayLink)?.isPaused = false
        } else if displayTimer == nil {
            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(displayTimerFired(_:)),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            displayTimer = timer
        }
        #else
        if displayLink == nil {
            let dl = CADisplayLink(target: self, selector: #selector(displayLinkFired(_:)))
            dl.add(to: .main, forMode: .common)
            displayLink = dl
        }
        updateDisplayLinkPreferredFrameRate()
        displayLink?.isPaused = false
        #endif
    }

    func stopDisplayLink() {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            (displayLinkStorage as? CADisplayLink)?.isPaused = true
        } else {
            displayTimer?.invalidate()
            displayTimer = nil
        }
        #else
        displayLink?.isPaused = true
        #endif
    }

    func invalidateDisplayLink() {
        #if os(macOS)
        displayTimer?.invalidate()
        displayTimer = nil
        if #available(macOS 14.0, *) {
            (displayLinkStorage as? CADisplayLink)?.invalidate()
            displayLinkStorage = nil
        }
        #else
        displayLink?.invalidate()
        displayLink = nil
        #endif
    }

    func updateDisplayLinkPreferredFrameRate() {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            (displayLinkStorage as? CADisplayLink)?.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60,
                maximum: 120,
                preferred: Float(min(120, max(60, cachedFPS.rounded())))
            )
        }
        #else
        guard let dl = displayLink else { return }
        if #available(iOS 15.0, *) {
            let range = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 0)
            dl.preferredFrameRateRange = range
        } else {
            dl.preferredFramesPerSecond = 60
        }
        #endif
    }

    #if os(macOS)
    @objc private func displayTimerFired(_ sender: Timer) {
        renderTick(presentationLead: fallbackPresentationLead)
    }
    #endif

    #if os(macOS)
    @available(macOS 14.0, *)
    #endif
    @objc private func displayLinkFired(_ sender: CADisplayLink) {
        let lead = max(0, min(0.05, sender.targetTimestamp - CACurrentMediaTime()))
        renderTick(presentationLead: lead)
    }

    var fallbackPresentationLead: Double {
        let fps = cachedFPS.isFinite && cachedFPS > 0 ? cachedFPS : 60
        return min(0.025, 0.75 / fps)
    }

    func renderTick(presentationLead: Double) {
        guard rate > 0 else {
            stopDisplayLink()
            return
        }
        displayTickCount += 1
        accumulatedPresentationLead += presentationLead
        let currentClock = currentTime + presentationLead * rate

        let sourceFPS = cachedFPS.isFinite && cachedFPS > 0 ? cachedFPS : 60
        let allowedVideoLag = max(0.025, 2.0 / sourceFPS)
        let result = frameQueue.dequeueBestFrame(
            before: currentClock,
            droppingFramesBefore: currentClock - allowedVideoLag
        )
        if let frame = result.frame {
            self.metalRenderer.update(with: frame.pixelBuffer)
            renderedFrameCount += 1
            timingDroppedFrameCount += max(0, result.consumedCount - 1)
            let coreInstance = core
            let consumedCount = result.consumedCount
            let generation = frame.generation
            Task {
                await coreInstance.acknowledgeVideoFrames(
                    consumedCount,
                    generation: generation
                )
            }
        } else {
            emptyDisplayTickCount += 1
            recoverStarvedDecodeFlowIfNeeded(currentClock: currentClock)
        }
        reportRenderStatsIfNeeded()
    }

    func reportRenderStatsIfNeeded() {
        let now = CACurrentMediaTime()
        let elapsed = now - renderStatsStartTime
        guard elapsed >= 5 else { return }

        let renderedFPS = Double(renderedFrameCount) / elapsed
        let averageLeadMS = displayTickCount > 0
            ? accumulatedPresentationLead / Double(displayTickCount) * 1_000
            : 0
        print(
            "📊 FFmpeg render: actual=\(String(format: "%.1f", renderedFPS))fps "
            + "source=\(String(format: "%.2f", cachedFPS))fps "
            + "queue=\(frameQueue.count) timingDrops=\(timingDroppedFrameCount) "
            + "ticks=\(displayTickCount) emptyTicks=\(emptyDisplayTickCount) "
            + "lead=\(String(format: "%.2f", averageLeadMS))ms"
        )
        renderStatsStartTime = now
        renderedFrameCount = 0
        timingDroppedFrameCount = 0
        displayTickCount = 0
        emptyDisplayTickCount = 0
        accumulatedPresentationLead = 0
    }

    func recoverStarvedDecodeFlowIfNeeded(currentClock: Double) {
        let now = CACurrentMediaTime()
        guard rate > 0,
              frameQueue.count == 0,
              currentClock < max(0, duration - 0.25),
              now - lastFrameArrivalTime > 0.75,
              now - lastSeekTime > 0.75,
              now - lastStarvationRecoveryTime > 0.75,
              !isStarvationRecoveryPending else { return }

        isStarvationRecoveryPending = true
        lastStarvationRecoveryTime = now
        let generation = currentFrameGeneration
        let expectedRate = rate
        let actualCount = frameQueue.count
        let coreInstance = core

        Task { [weak self] in
            let recovery = await coreInstance.recoverStarvedDecodeFlow(
                generation: generation,
                actualQueueCount: actualCount,
                expectedRate: expectedRate
            )
            guard let self else { return }
            self.isStarvationRecoveryPending = false
            guard generation == self.currentFrameGeneration, let recovery else { return }

            if recovery.previousCount != actualCount || recovery.restarted || recovery.resumed {
                print(
                    "🩹 FFmpeg decode starvation recovered: coreQueue=\(recovery.previousCount) "
                    + "actualQueue=\(actualCount) restarted=\(recovery.restarted) "
                    + "resumed=\(recovery.resumed)"
                )
            }
        }
    }
}
