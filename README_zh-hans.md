# Strophe 活字

[English](README.md)

**Strophe**（活字）是一款专为 Apple 平台打造的高性能、专业级字幕制作工具。它结合了现代化的 **Liquid Glass** 设计美学与工业级的音视频处理技术，旨在为创作者提供极致丝滑的字幕制作体验。

<img src="Strophe.icon/Assets/ChatGPT%20Image%202026年5月20日%2020_42_12.png" alt="Strophe Logo" width="300">

## ✨ 核心特性

### 视频播放

- **FFmpeg 驱动引擎**：完整支持 AVFoundation 原生不支持的各种格式，包括 MKV、WebM、FLV、AVI 等
- **VideoToolbox 硬件加速**：H.264/H.265 零拷贝 GPU 解码，CPU 占用极低
- **Metal 渲染**：高性能 GPU BT.709 色彩转换，确保视频显示准确
- **跨平台支持**：原生支持 macOS 和 iOS

### 波形与时间轴

- **高性能波形引擎**：基于 `Accelerate` 框架与 `vDSP` 技术，实现 Peak（瞬态）与 RMS（能量包络）的双层实时渲染
- **ProMotion 全帧率同步**：采用插值算法与 `TimelineView` 驱动，支持 120Hz 刷新率，确保时间轴滚动丝滑顺畅
- **Logic Pro 级交互**：
  - **智能缩放**：支持 `Option + 滚轮` 快速缩放，标尺刻度自动调整精度
  - **专业播放头**：可拖拽的磁吸式播放头，支持实时 Scrubbing
  - **自动随动**：播放时画面自动居中，确保创作焦点不丢失

### 字幕编辑

- **J/K 打轴模式**：专业的节奏式字幕打点，使用 J 和 K 键快速定位
- **选择与创建工具**：在选择模式和创建模式间切换，高效完成工作流
- **帧精确时间轴**：根据视频帧率自动吸附到精确帧
- **重叠检测**：字幕块重叠时的视觉提示
- **软字幕预览**：实时预览内嵌字幕

### 项目管理

- **.strophe 项目格式**：保存并恢复完整的项目状态，包括媒体引用
- **自动保存**：每 30 秒自动保存项目
- **导出功能**：从项目生成 SRT 字幕文件

### 现代设计

- **Liquid Glass UI**（macOS 26+ / iOS 26+）：精美的半透明材质与生动的深度效果
- **旧版兼容**：为旧版 macOS/iOS 提供简洁的回退样式
- **深色模式**：完整支持系统外观偏好
- **键盘快捷键**：为高级用户提供全面的快捷键支持

## 🚀 快速开始

1. **导入媒体**：将视频或音频文件拖入应用窗口
2. **时间轴操作**：
   - `Option + 滚轮`：缩放时间轴
   - `点击波形`：快速跳转进度
   - `拖拽播放头`：精细预览音频细节
3. **字幕编辑**：
   - 使用**选择工具**（V）选择并移动字幕块
   - 使用**创建工具**（D）创建新的字幕块
   - 按 **J/K** 键进行节奏式打点（打轴模式）
4. **导出**：保存项目或导出为 SRT 格式

## ⌨️ 键盘快捷键

| 操作     | 快捷键   |
| ------ | ----- |
| 播放/暂停  | Space |
| 选择工具   | V     |
| 创建工具   | D     |
| 软字幕预览  | ⌥S    |
| 前进 5 秒 | ⌘→    |
| 后退 5 秒 | ⌘←    |
| 保存项目   | ⌘S    |
| 项目另存为  | ⇧⌘S   |

## 🛠️ 技术架构

- **语言**：Swift 6 (Strict Concurrency)
- **框架**：SwiftUI, AVFoundation, Metal, Accelerate
- **视频引擎**：FFmpeg (via Libav\*) + VideoToolbox 集成
- **音频引擎**：AVAudioEngine 实时重采样
- **渲染方案**：Metal + Canvas + GPU DrawingGroup Cache
- **数学引擎**：Accelerate (vDSP) 波形处理

## 📋 支持格式

### 视频容器

- MP4, MOV, M4V（通过 AVFoundation）
- MKV, WebM, FLV, AVI, RMVB（通过 FFmpeg）

### 音频格式

- AAC, MP3, WAV, FLAC, Opus 等

### 字幕格式

- 导入：纯文本, SRT
- 导出：SRT

## 📄 开源协议

本项目采用 [Functional Source License](LICENSE) 协议，因此属于**有源软件**。
