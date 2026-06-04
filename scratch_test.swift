import AVFoundation

Task {
    let player = AVPlayer()
    _ = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
}
