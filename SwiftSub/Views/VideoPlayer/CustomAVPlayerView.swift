//
//  CustomAVPlayerView.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI
import AVFoundation

// MARK: - CustomAVPlayerView (Direct AVPlayerLayer wrapper bypassing AVKit)
#if os(macOS)
struct CustomAVPlayerView: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = view.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        
        view.layer?.addSublayer(playerLayer)
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let playerLayer = nsView.layer?.sublayers?.first(where: { $0 is AVPlayerLayer }) as? AVPlayerLayer {
            if playerLayer.player != player {
                playerLayer.player = player
            }
        }
    }
}
#else
class PlayerContainerView: UIView {
    private let playerLayer: AVPlayerLayer
    
    init(player: AVPlayer) {
        self.playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        self.backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        self.layer.addSublayer(playerLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
    
    func updatePlayer(_ player: AVPlayer) {
        if playerLayer.player != player {
            playerLayer.player = player
        }
    }
}

struct CustomAVPlayerView: UIViewRepresentable {
    let player: AVPlayer
    
    func makeUIView(context: Context) -> PlayerContainerView {
        return PlayerContainerView(player: player)
    }
    
    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.updatePlayer(player)
    }
}
#endif
