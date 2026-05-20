# Strophe 活字

[简体中文](README_zh-hans.md)

**Strophe** is a high-performance, professional-grade subtitle authoring tool built natively for Apple platforms. It combines modern **Liquid Glass** design aesthetics with industrial-grade audio/video processing technology, delivering an ultra-smooth subtitling experience for creators.

<img src="Strophe.icon/Assets/ChatGPT%20Image%202026年5月20日%2020_42_12.png" alt="Strophe Logo" width="300">

## ✨ Core Features

### Video Playback

- **FFmpeg-Powered Engine**: Full support for formats not natively supported by AVFoundation, including MKV, WebM, FLV, AVI, and more
- **VideoToolbox Hardware Acceleration**: Zero-copy GPU decoding for H.264/H.265 with minimal CPU usage
- **Metal Rendering**: High-performance GPU-based BT.709 color conversion for accurate video display
- **Cross-Platform**: Native support for both macOS and iOS

### Waveform & Timeline

- **High-Performance Waveform Engine**: Real-time dual-layer rendering of Peak (transient) and RMS (energy envelope) using `Accelerate` framework and `vDSP`
- **ProMotion Full Frame Rate**: Interpolation algorithms and `TimelineView`-driven rendering supporting 120Hz displays
- **Logic Pro-Style Interactions**:
  - **Smart Zoom**: `Option + Scroll` for rapid zooming with automatic ruler precision adjustment
  - **Professional Playhead**: Draggable magnetic playhead with real-time scrubbing
  - **Auto-Follow**: Automatic centering during playback to maintain creative focus

### Subtitle Editing

- **J/K Slapping Mode**: Professional rhythm-based subtitle timing using J and K keys
- **Selection & Creation Tools**: Switch between selection mode and creation mode for efficient workflow
- **Frame-Accurate Timing**: Automatic frame snapping based on video frame rate
- **Overlap Detection**: Visual indicators for overlapping subtitle blocks
- **Soft Subtitle Preview**: Real-time preview of embedded subtitles

### Project Management

- **.strophe Project Format**: Save and restore complete project state including media references
- **Auto-Save**: Automatic project saving every 30 seconds
- **Export**: Generate SRT subtitle files from your projects

### Modern Design

- **Liquid Glass UI** (macOS 26+ / iOS 26+): Beautiful translucent materials with vibrant depth effects
- **Legacy Support**: Clean fallback styling for older macOS/iOS versions
- **Dark Mode**: Full support for system appearance preferences
- **Keyboard Shortcuts**: Comprehensive keyboard shortcuts for power users

## 🚀 Quick Start

1. **Import Media**: Drag and drop a video or audio file into the application window
2. **Timeline Navigation**:
   - `Option + Scroll`: Zoom timeline in/out
   - `Click waveform`: Jump to position
   - `Drag playhead`: Fine-grained audio preview
3. **Subtitle Editing**:
   - Use **Selection Tool** (V) to select and move subtitle blocks
   - Use **Creation Tool** (D) to create new subtitle blocks
   - Press **J/K** keys for rhythm-based timing (slapping mode)
4. **Export**: Save your project or export to SRT format

## ⌨️ Keyboard Shortcuts

| Action                | Shortcut |
| --------------------- | -------- |
| Play/Pause            | Space    |
| Selection Tool        | V        |
| Creation Tool         | D        |
| Soft Subtitle Preview | ⌥S       |
| Skip Forward 5s       | ⌘→       |
| Skip Backward 5s      | ⌘←       |
| Save Project          | ⌘S       |
| Save Project As       | ⇧⌘S      |

## 🛠️ Technical Architecture

- **Language**: Swift 6 (Strict Concurrency)
- **Frameworks**: SwiftUI, AVFoundation, Metal, Accelerate
- **Video Engine**: FFmpeg (via Libav\*) with VideoToolbox integration
- **Audio Engine**: AVAudioEngine with real-time resampling
- **Rendering**: Metal + Canvas with GPU DrawingGroup Cache
- **Math Engine**: Accelerate (vDSP) for waveform processing

## 📋 Supported Formats

### Video Containers

- MP4, MOV, M4V (via AVFoundation)
- MKV, WebM, FLV, AVI, RMVB (via FFmpeg)

### Audio Formats

- AAC, MP3, WAV, FLAC, Opus, and more

### Subtitle Formats

- Import: Plain text, SRT
- Export: SRT

## 📄 License

This project is open-sourced under the [Functional Source License](LICENSE).
