# Strophe 🌊

**Strophe** 是一款专为 macOS 打造的高性能、专业级字幕制作工具。它结合了现代化的 **Liquid Glass** 设计美学与工业级的音频处理技术，旨在为创作者提供极致丝滑的打点与剪辑体验。

## ✨ 核心特性

- **高性能波形引擎**：基于 `Accelerate` 框架与 `vDSP` 技术，实现 Peak（瞬态）与 RMS（能量包络）的双层实时渲染。
- **ProMotion 全帧率同步**：采用插值算法与 `TimelineView` 驱动，支持 120Hz 刷新率，确保时间轴滚动丝滑顺畅。
- **Logic Pro 级交互**：
  - **智能缩放**：支持 `Option + 滚轮` 快速缩放，标尺刻度自动调整精度。
  - **专业播放头**：可拖拽的磁吸式播放头，支持实时 Scrubbing。
  - **自动随动**：播放时画面自动居中，确保创作焦点不丢失。
- **现代 macOS 体验**：全原生 SwiftUI 开发，完美适配 macOS 材质与深色模式，支持文件拖拽导入。

## 🚀 快速开始

1. **导入媒体**：将视频或音频文件拖入应用窗口。
2. **波形操作**：
   - `Option + 滚轮`：缩放时间轴。
   - `点击波形`：快速跳转进度。
   - `拖拽播放头`：精细预览音频细节。
3. **字幕编辑**：基于精准的波形能量图，快速定位话音起止点，进行高效打点。

## 🛠️ 技术架构

- **语言**：Swift 6 (Strict Concurrency)
- **框架**：SwiftUI, AVFoundation
- **数学引擎**：Accelerate (vDSP)
- **渲染方案**：Canvas + GPU DrawingGroup Cache

## 📄 开源协议

本项目采用 [Functional Source License](LICENSE) 协议开源。
