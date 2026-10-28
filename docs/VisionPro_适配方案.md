# Strophe 的 Apple Vision Pro（visionOS）适配方案

> 与 `iPhoneDuo_适配方案.md` 并列：iPhone Duo 解决“折叠/双屏的紧凑布局”，本文解决“Apple Vision Pro 上的空间多窗口布局”。
>
> 目标系统：visionOS 2.0+（工程当前 `XROS_DEPLOYMENT_TARGET = 2.0`）。实测环境：Xcode 27.2 / Apple Vision Pro 模拟器（visionOS 27.2）。
>
> 结论：**可以拆，而且应该用原生多窗口来拆。** 视频、时间线、字幕预览、样式编辑器都可以成为独立窗口；每个窗口由用户自由移动、缩放，并可在 visionOS 26 上吸附到墙面/桌面并锁定。但“一个窗口内部任意拖拽悬浮面板”“窗口旋转”“窗口始终置顶”不是系统能力；App 也不能在窗口出现后程序化移动或缩放它。

---

## 0. 一句话结论

在 Vision Pro 上，最合适的“自由组合”不是把 `ZStack` 里的面板做拖拽，而是：

**把编辑器拆成多个 SwiftUI Scene（Window / WindowGroup），共享同一个 `SubtitleProject` 与 `PlayerEngine`，让系统窗口管理器负责移动、缩放、遮挡和恢复。**

这正好契合 Strophe 的组件结构：视频、时间线、样式、字幕列表本来就是相对独立的视图，拆窗口的改造成本低于重写一套“空间 CAD 式”面板系统。

---

## 1. 需求可行性判断

| 你想要的 | 能否 | 正确做法 | 关键限制 |
|---|---|---|---|
| 视频独立成窗 | 可以 | `Window("Video", id: "video")` + 现有 `VideoPlayerView` | 首版只允许一个视频窗口；不要假设同一个播放器 `UIView` 能同时挂到两个窗口 |
| 时间线独立成窗 | 可以 | `Window("Timeline", id: "timeline")` + 现有时间线视图 | 每个窗口有自己的视口/滚动状态；工程数据共享 |
| 样式窗口独立 | 可以 | `WindowGroup("Style", id: "style", for: UUID.self)` | 可同时打开多个不同样式的窗口；同一 `UUID` 只会有一个窗口 |
| 字幕预览/提词独立成窗 | 可以 | `Window("Subtitle", id: "subtitle")` + 只读字幕层 | 字幕文本应订阅同一个 `currentTime` / 当前字幕 |
| 用户拖动窗口、调整大小 | 可以 | 系统窗口栏拖动、右下/左下角缩放；配合 `.windowResizability(.contentMinSize)` | App 只能在窗口首次出现时给默认位置/尺寸，之后不能程序化移动或缩放 |
| 窗口旋转/倾斜 | 不可以 | 系统不提供窗口旋转；窗口是面向用户的竖直平面 | 只有 Volume 可以从任意角度看，但 Volume 是固定尺寸的 3D 容器，不适合编辑器 UI |
| 窗口始终置顶 / 浮在视频上方 | 不可以（visionOS） | `WindowLevel` 只在 macOS 可用 | 窗口的前后关系由空间中的物理遮挡决定；样式窗口可以放在视频旁边，但不能强制置顶 |
| 把拆出去的窗口再合并回主窗口 | 可以 | 关闭独立窗口，主窗口恢复内嵌视频/时间线；用工作区状态控制 | 需要“占位/隐藏”逻辑，避免主窗口和独立窗口同时挂同一个播放器视图 |
| 在一个窗口内部任意拖拽子面板 | 不推荐/非原生 | 只能自绘悬浮容器，或用 RealityKit 的 View Attachment 把 SwiftUI 视图挂到 3D 实体上 | 会失去系统窗口栏、焦点、文本输入、无障碍和状态恢复；不建议作为编辑器主方案 |
| 沉浸式影院/空间视频编辑 | 可做，但放 P2 | `AVPlayerViewController` 全窗口播放；visionOS 26 的 `AVExperienceController` / `VideoPlayerComponent` | 同一时间系统只允许一个 Immersive Space；自定义 SwiftUI 字幕覆盖层在沉浸模式下不可依赖 |

**直接回答“能不能自由组合拆分”：**
可以拆成独立窗口，并由用户在空间里自由摆放、缩放；但它是“系统窗口级”的自由，不是“窗口内任意悬浮面板级”的自由。App 能提供初始布局预设，不能替用户决定最终位置。

---

## 2. 当前项目基线（已实测）

### 2.1 工程其实已经“半只脚”在 visionOS 上

- [project.pbxproj](file:///Volumes/KIOXIA/code/Strophe/Strophe.xcodeproj/project.pbxproj#L539-L550) 已包含：
  - `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx xros xrsimulator"`
  - `TARGETED_DEVICE_FAMILY = "1,2,7"`
  - `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = NO`
  - `XROS_DEPLOYMENT_TARGET = 2.0`
- 代码里已有少量 `#if os(visionOS)` 分支（侧栏材质、Tab Bar 等）。
- FFmpeg 的 xcframework 已包含 `xros-arm64` 与 `xros-arm64-simulator` 切片；因此 **Apple Silicon 上的 visionOS 模拟器可以完整编译、链接、启动**。
- 实测命令：

```bash
xcodebuild -project Strophe.xcodeproj -scheme Strophe \
  -configuration Debug \
  -destination 'platform=visionOS Simulator,id=<Apple Vision Pro>' \
  -derivedDataPath /tmp/strophe-vision-build \
  CODE_SIGNING_ALLOWED=NO build
# BUILD SUCCEEDED
```

注意：FFmpeg 的 xcframework 没有 `x86_64` 模拟器切片。通用 `generic/platform=visionOS Simulator` 会在 Intel 架构链接阶段报 `symbol(s) not found for architecture x86_64`；CI 使用 Apple Silicon runner，或补 `x86_64` 切片即可。

### 2.2 但当前只有“一个窗口”

[StropheApp.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/App/StropheApp.swift#L137-L141) 在 visionOS 上只有：

```swift
WindowGroup {
    WelcomeRouterView(project: project)
}
```

没有 window id、没有 `defaultSize`、没有视频/时间线/样式的独立 Scene，也没有 `.defaultWindowPlacement`。因此现在只能得到“一个窗口里塞下全部编辑器”。

### 2.3 实测截图

![当前 visionOS 模拟器实测](docs/images/visionos-current.jpg)

这是当前构建在 Apple Vision Pro 模拟器中的实际界面。可以直观看到三个需要处理的问题：

1. **整块深色不透明背景**：窗口自身的玻璃材质被 `Color.stropheBackground` 覆盖，空间感丢失。
2. **侧栏底部是自绘 Tab Bar**：visionOS 原生 Tab Bar 应该是窗口前缘的竖直 Ornament，注视时自动展开；当前是底部小图标条。
3. **顶部是自绘工具栏/窗口按钮**：与系统窗口栏、关闭按钮争夺同一区域；控制项也太小，不适合眼动+捏合。

对应代码：

- [Layouts.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Main/ContentView/Layouts.swift#L16-L40)：`NavigationSplitView` + `.background(Color.stropheBackground)`。
- [StropheSidebarContainer.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Sidebar/StropheSidebarContainer.swift#L25-L32)：visionOS 分支额外叠了 `.ultraThinMaterial`。
- [StropheTabBar.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Navigation/StropheTabBar.swift#L59-L70)：visionOS 直接使用自绘 `ordinaryTabBar`。
- [MainContentView.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Main/MainContentView.swift#L166-L175)：工具栏仍按 iOS/macOS 的 placement 渲染。

适配后（P0 完成）的同一界面：

![P0 完成后：原生 Tab Ornament + 玻璃背景](docs/images/visionos-native-tabbar.jpg)

窗口前缘出现了 visionOS 原生竖直 Tab Ornament，侧栏不再叠加自绘 Tab 和 material，内容背景改为系统玻璃。

### 2.4 当前架构里对多窗口有利的部分

- `project` 是 App 级 `@StateObject`，所有 Scene 可以共享同一份工程模型。
- `PlayerEngine` 已经是“工程级单播放器”的设计，时间线、字幕遮罩、波形都围绕它工作。
- 样式数据在 `StyleAndGroupStore.shared`，样式窗口可以共享。
- 视频/时间线/样式视图之间没有强耦合的父子层级，适合切成独立 Scene。

这决定了：**多窗口不是重写，而是“把现有视图搬到新的 Scene 容器里 + 处理共享视图的归属”。**

---

## 3. 空间组件拆分设计

### 3.1 模块与 Scene 映射

| 模块 | Scene 类型 | 是否允许多个 | 建议尺寸 / 最小尺寸 | 初始位置 | 说明 |
|---|---|---|---|---|---|
| 编辑器主窗口 | `Window("Editor", id: "editor")` | 否（当前单工程模型） | 1280×800 / 1000×640 | 系统放在用户注视处 | 保留侧栏、脚本列表、设置；拆窗口后可只显示项目导航与字幕列表 |
| 视频窗口 | `Window("Video", id: "video")` | 否（首版） | 960×540 / 640×360 | 编辑器右侧 | 黑底视频 + 字幕覆盖层 + 播放 Ornament；主窗口隐藏内嵌视频 |
| 时间线窗口 | `Window("Timeline", id: "timeline")` | 否（首版） | 1280×420 / 900×300 | 视频下方或编辑器下方 | 波形、字幕块、播放头、时间线工具栏；视口状态按窗口独立 |
| 字幕预览/提词窗口 | `Window("Subtitle", id: "subtitle")` | 否 | 800×300 / 600×240 | 视频下方 | 只读大字幕、当前句/下一句；适合审片和配音 |
| 样式编辑器窗口 | `WindowGroup("Style", id: "style", for: UUID.self)` | 是（按样式 ID） | 420×760 / 380×620 | `utilityPanel` | 可同时打开多个不同样式，做并排对比；同一 ID 只出现一个窗口 |
| 设置窗口 | `Window("Settings", id: "settings")` | 否 | 640×720 / 560×640 | 编辑器左侧或 `utilityPanel` | visionOS 上不要依赖 `Settings` Scene；用普通 Window |
| 导出进度/临时面板 | 主窗口内 `sheet` / overlay | 否 | — | — | 短期任务不单独开窗，避免窗口膨胀 |

### 3.2 三种工作模式

**模式 A：聚合模式（默认，保持现有体验）**

```
┌──────────────────────────────────────────────┐
│ 窗口栏 / 标题                                  │
│ ┌──────────┬───────────────────────────────┐ │
│ │ 侧栏      │ 视频 + 字幕覆盖层              │ │
│ │ 脚本列表  ├───────────────────────────────┤ │
│ │ Tab Bar  │ 时间线 + 工具栏                 │ │
│ └──────────┴───────────────────────────────┘ │
└──────────────────────────────────────────────┘
```

**模式 B：审片模式（视频独立）**

```
┌──────────────────────┐      ┌──────────────────────┐
│ 编辑器/字幕列表        │      │ 视频 + 字幕 + 播放控制  │
│                      │      │                      │
│ 选中句 → 视频跳转      │      │ 时间线可留在主窗口或独立 │
└──────────────────────┘      └──────────────────────┘
```

**模式 C：空间工作台（全拆）**

```
        ┌──────────────────────┐
        │ 视频窗口               │
        │ 字幕覆盖层 / 播放 Ornament│
        └──────────┬───────────┘
                   │
┌────────────┐  ┌──┴───────────┐  ┌──────────────┐
│ 主窗口      │  │ 时间线窗口     │  │ 样式窗口 × N   │
│ 项目/字幕   │  │ 波形/字幕块    │  │ 字体/描边/位置 │
└────────────┘  └──────────────┘  └──────────────┘
```

**模式 D：样式实验室（并排比较）**

```
┌──────────────────────┐  ┌────────────┐  ┌────────────┐
│ 视频窗口               │  │ 样式 A 窗口 │  │ 样式 B 窗口 │
│ 同一句字幕实时预览       │  │ 编辑 A      │  │ 编辑 B      │
└──────────────────────┘  └────────────┘  └────────────┘
```

模式 D 是 Vision Pro 上最有价值的差异化能力：同一句字幕、同一时间点，两个样式窗口并排实时改，视频窗口立刻反馈。

### 3.3 App Scene 骨架（示意）

```swift
import SwiftUI

@main
struct StropheApp: App {
    @StateObject private var project = SubtitleProject()
    @StateObject private var workspace = SpatialWorkspaceModel()

    var body: some Scene {
        Window("Strophe", id: "editor") {
            ContentView(project: project, workspace: workspace)
                .frame(minWidth: 1_000, minHeight: 640)
        }
        .defaultSize(width: 1_280, height: 800)
        .windowResizability(.contentMinSize)

        Window("Video", id: "video") {
            VideoWindowView(project: project, workspace: workspace)
                .frame(minWidth: 640, minHeight: 360)
        }
        .defaultSize(width: 960, height: 540)
        .windowResizability(.contentMinSize)
        .defaultWindowPlacement { _, context in
            guard let editor = context.windows.first(where: { $0.id == "editor" }) else {
                return WindowPlacement()
            }
            return WindowPlacement(.trailing(editor))
        }

        Window("Timeline", id: "timeline") {
            TimelineWindowView(project: project, workspace: workspace)
                .frame(minWidth: 900, minHeight: 300)
        }
        .defaultSize(width: 1_280, height: 420)
        .windowResizability(.contentMinSize)

        Window("Subtitle", id: "subtitle") {
            SubtitleMonitorWindowView(project: project)
                .frame(minWidth: 600, minHeight: 240)
        }
        .defaultSize(width: 800, height: 300)
        .windowResizability(.contentMinSize)

        WindowGroup("Style", id: "style", for: UUID.self) { $styleID in
            if let styleID {
                StyleWindowView(project: project, styleID: styleID)
            } else {
                Text("样式已删除")
            }
        }
        .defaultSize(width: 420, height: 760)
        .windowResizability(.contentMinSize)
        .defaultWindowPlacement { _, _ in
            WindowPlacement(.utilityPanel)
        }
    }
}
```

说明：

- `Window` 是单实例窗口；`WindowGroup` 才能多开。视频/时间线/字幕用 `Window`，样式用 `WindowGroup(for: UUID.self)`。
- `WindowPlacement(.utilityPanel)` 是 visionOS 2.0+ 的语义位置，适合样式检查器。
- `WindowPlacement(.trailing(editor))` 只影响**首次出现**；用户之后移动/缩放，系统优先恢复用户最近的位置。
- 首个窗口的 `defaultWindowPlacement` 在 visionOS 上会被系统忽略，系统把首个窗口放在用户注视处，这是预期行为。
- visionOS 26+ 可以使用 `.defaultLaunchBehavior(.suppressed)` 阻止次要窗口在启动时自动出现；2.0 上不加这个修饰符即可。

### 3.4 共享状态与“谁拥有播放器”

推荐新增一个轻量的 `SpatialWorkspaceModel`，只管理“窗口模式”和“窗口是否已打开”，不管理工程数据：

```swift
@MainActor
final class SpatialWorkspaceModel: ObservableObject {
    enum Mode { case combined, review, workbench, styleLab }
    @Published var mode: Mode = .combined
    @Published var isVideoWindowOpen = false
    @Published var isTimelineWindowOpen = false
}
```

关键规则：

1. **视频窗口是单一宿主。** `PlayerEngine` 内部持有一个 `hostView`/`AVPlayerLayer`。同一个 host view 不能同时挂在主窗口和独立视频窗口上；否则会出现“后挂的窗口黑屏/前一个窗口空白”。
2. 主窗口在 `isVideoWindowOpen == true` 时显示占位卡，而不是再创建一份视频视图：

```swift
if workspace.isVideoWindowOpen {
    DetachedModulePlaceholder(title: "视频已在独立窗口播放")
} else {
    VideoPlayerView(project: project)
}
```

3. 视频窗口在 `onAppear` 设置 `isVideoWindowOpen = true`；在 `onDisappear` 或 `scenePhase == .background` 时复位：

```swift
.onAppear { workspace.isVideoWindowOpen = true }
.onDisappear { workspace.isVideoWindowOpen = false }
.onChange(of: scenePhase, initial: true) { _, phase in
    if phase == .background { workspace.isVideoWindowOpen = false }
}
```

4. 关闭视频窗口后，主窗口重新内嵌视频时，`PlayerEngine` 只需要把同一个 host view 重新加到新的父视图；不要创建第二个 `AVPlayerLayer`，除非先验证“同一 `AVPlayer` 绑多个 layer”的行为和性能。
5. 时间线不存在“单一宿主”问题，可以在主窗口和独立窗口各有一份，但建议首版也只开一个，避免两个时间线争夺滚动/选中焦点。

### 3.5 样式窗口：多开与实时预览

当前样式编辑器是 sheet：

- [StyleEditSheet.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Style/StyleEditSheet.swift#L15-L18) 通过 `@Binding isPresented` / `selectedStyleId` 工作。
- [MainContentView.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Main/MainContentView.swift#L270-L283) 以 `.sheet` 呈现。

改造成独立窗口时：

```swift
struct StyleWindowView: View {
    @ObservedObject var project: SubtitleProject
    let styleID: UUID
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        StyleEditorContent(project: project, styleID: styleID, mode: .window)
            .frame(minWidth: 380, minHeight: 620)
    }
}
```

打开多个样式：

```swift
@Environment(\.openWindow) private var openWindow
@Environment(\.dismissWindow) private var dismissWindow

Button("并排编辑样式") {
    openWindow(id: "style", value: styleA.id)
    openWindow(id: "style", value: styleB.id)
}

Button("关闭该样式窗口") {
    dismissWindow(id: "style", value: styleA.id)
}
```

注意：

- `WindowGroup(for: UUID.self)` 对同一个值只会打开一个窗口，重复 `openWindow` 会把已有窗口带到前面，这正是我们想要的。
- 样式被删除时，窗口里的 `styleID` 失效；应显示空状态并调用 `dismissWindow(id:value:)`，不要让窗口崩溃。
- 样式窗口的改动应实时写入共享的 `StyleAndGroupStore`，这样视频窗口和时间线立即刷新；如果保留“保存/取消”语义，就要接受“并排对比时不能实时看效果”的体验损失。建议样式窗口采用**实时应用 + 撤销**，而不是模态保存。

### 3.6 窗口尺寸、初始位置与恢复

Apple 的 visionOS HIG 给出的默认窗口是 **1280×720 pt**，系统把窗口放在约 2 米处，视觉宽度约 3 米。我们的尺寸以此为基准，不要做“全屏 4K 画布”的假设。

| 窗口 | 默认 | 最小 | 最大 | 初始位置 |
|---|---|---|---|---|
| 编辑器 | 1280×800 | 1000×640 | 随内容 | 首个窗口，系统放置 |
| 视频 | 960×540 | 640×360 | 不限制 | 编辑器 trailing |
| 时间线 | 1280×420 | 900×300 | 不限制 | 视频 below 或编辑器 below |
| 字幕 | 800×300 | 600×240 | 不限制 | 视频 below |
| 样式 | 420×760 | 380×620 | 560×900 | `utilityPanel` |
| 设置 | 640×720 | 560×640 | 不限制 | 编辑器 leading |

实现要点：

```swift
content
    .frame(minWidth: 960, minHeight: 540)
.windowResizability(.contentMinSize)   // 允许放大，不允许小于内容最小尺寸
.defaultSize(width: 1_280, height: 720)
```

- `.windowResizability(.contentSize)` 会把窗口锁死在内容尺寸，**不适合**需要用户缩放的时间线/视频窗口。
- `.windowResizability(.automatic)` 对普通窗口默认等价于 `contentMinSize`；但显式写 `.contentMinSize` + `.frame(minWidth:minHeight:)` 更可控。
- 窗口的位置/尺寸在 state restoration 时优先恢复用户上次的结果，而不是 `defaultWindowPlacement`。所以“布局预设”只在窗口**首次创建**时有效；用户拖过之后，App 不能再改。
- visionOS 26 起，用户可以把窗口吸附到墙面并锁定，锁定的可恢复窗口会在重启/换房间后保持位置。这正好适合“固定工作台”场景；不要把这种窗口的 `restorationBehavior` 设为 `.disabled`。

### 3.7 “自由组合”的边界

必须写进产品说明，避免预期错位：

1. **App 不能程序化移动/缩放已出现的窗口。** Apple 文档明确：窗口出现后，App 不能直接操作位置或尺寸，以保证用户对工作区的控制。
2. **窗口不能旋转。** 窗口始终面向用户；只有 Volume 可从任意角度看，但 Volume 尺寸固定、`contentSize` 策略，不适合编辑器。
3. **没有“始终置顶”。** `WindowLevel` 是 macOS 15+ API，visionOS 不可用。样式窗口可以放在视频旁边，但是否被遮挡取决于空间深度和用户位置。
4. **多窗口 ≠ 多工程。** 当前 `project` 是单实例；如果把编辑器做成 `WindowGroup`，两个编辑器窗口会共享同一工程，且可能同时持有视频视图。首版用 `Window` 单编辑器，后续再做 `DocumentGroup` 多工程。
5. **沉浸式空间只允许一个。** 如果未来做“影院审片”，同一时间只有一个 Immersive Space；不要把它当作普通编辑布局。

---

## 4. 空间交互与视觉适配

### 4.1 窗口背景：保留系统玻璃，不要铺不透明底色

visionOS 的默认窗口本身就是一块带玻璃材质的竖直平面，带关闭按钮、窗口栏、缩放控制。HIG 要求保留这层玻璃，避免不透明背景把空间感完全遮住。

当前实现的问题：

- [Layouts.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Main/ContentView/Layouts.swift#L34) 直接 `.background(Color.stropheBackground)`。
- [StropheSidebarContainer.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Sidebar/StropheSidebarContainer.swift#L25-L32) 又在侧栏叠了 `.ultraThinMaterial` 圆角层。

建议：

```swift
#if os(visionOS)
    content
        .background(.clear)          // 让系统窗口玻璃透出来
#else
    content
        .background(Color.stropheBackground)
#endif
```

- 视频区域保留 `.black`，这是内容本身，不是窗口底色。
- 侧栏不要再叠一层大圆角 material；用分隔线、留白和系统玻璃区分层级。
- 自定义播放控制/样式浮层如果需要底色，用 `glassBackgroundEffect()` 或系统 `Material`，并且只包住控件本身，不要包住整个窗口。
- 不要把系统窗口栏隐藏掉；内容顶部预留窗口栏高度，避免自绘按钮和关闭按钮重叠。

### 4.2 导航：用原生 TabView，而不是侧栏底部自绘 Tab

visionOS 的 Tab Bar 是**窗口前缘的竖直 Ornament**，注视时自动展开，选中后收起。它和 iOS 底部 Tab Bar 的交互模型不同。

当前：

- [StropheSidebarContainer.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Sidebar/StropheSidebarContainer.swift#L52-L75) 把 `StropheTabBar` 放在侧栏底部。
- [StropheTabBar.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Navigation/StropheTabBar.swift#L59-L70) 在 visionOS 上用 `ordinaryTabBar`。

建议在 visionOS 上走原生 `TabView`：

```swift
#if os(visionOS)
TabView(selection: $selectedTab) {
    Tab("脚本", systemImage: "list.bullet", value: StropheTab.scriptList) {
        ScriptListView(...)
    }
    Tab("样式", systemImage: "textformat", value: StropheTab.style) {
        StyleListView(...)
    }
    Tab("设置", systemImage: "gearshape", value: StropheTab.settings) {
        SettingsRootView(...)
    }
}
#else
existingCustomTabBar
#endif
```

- 不要在 visionOS 上给 `TabView` 指定 `.sidebarAdaptable`；默认的竖直 Tab Bar 就是 visionOS 的形态。
- 编辑器内部仍然可以用 `NavigationSplitView`（侧栏 + 详情），但顶层导航交给 Tab Bar。
- Tab Bar 展开时会暂时遮挡内容，这是系统行为；不要为了“永不遮挡”做自绘。

### 4.3 工具栏与 Ornament

visionOS 的 toolbar item 默认可以进入窗口底部的 Ornament；也可以直接用 `.ornament(attachmentAnchor:)` 放自定义控制条。

```swift
.toolbar {
    ToolbarItemGroup(placement: .bottomOrnament) {
        Button("播放", systemImage: "play.fill") { ... }
        Button("上一句", systemImage: "backward.end.fill") { ... }
        Button("下一句", systemImage: "forward.end.fill") { ... }
    }
}
```

或者自定义：

```swift
.ornament(attachmentAnchor: .scene(.bottom)) {
    HStack(spacing: 16) {
        PlaybackTransport()
        Divider().frame(height: 24)
        ExportMenu()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .glassBackgroundEffect()
}
```

建议：

- 视频窗口：播放/上一句/下一句/循环/导出放底部 Ornament；窗口内只保留画面和字幕。
- 时间线窗口：高频操作（分割、合并、吸附、缩放）放 Ornament；低频操作收进 `Menu`，避免一排小图标。
- 不要继续用 `.help()` 作为主要提示；visionOS 没有鼠标悬停提示的稳定交互，重要操作要有文字标签或菜单项。
- `bottomOrnament` 和 `ornament` 都是 visionOS 1.0+，当前 2.0 目标可用。

### 4.4 眼动 + 捏合：目标尺寸、Hover 与手势

visionOS 的输入是“注视 + 捏合 + 拖拽”，没有触摸屏的直接触点。

关键规则：

- 标准控件会被系统自动扩展到至少 **60×60 pt** 的交互区域；但**自绘 Metal 内容不会**。
- 自绘时间线字幕块必须自己做 hover 高亮和命中扩展，否则用户很难用眼睛精确瞄准。
- 当前时间线字号是 `11.5 * displayScale`（[MetalTimelineTextAtlas.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Timeline/Metal/MetalTimelineTextAtlas.swift#L113)），字幕块高度 28pt（[SubtitleTimelineGeometry.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Timeline/SubtitleBlocks/SubtitleTimelineGeometry.swift#L20)）。在 2 米距离下偏小，建议在 visionOS 上：
  - 时间线文字至少 13.5-15pt；
  - 字幕块保留 28pt 视觉高度，但命中区扩到 60pt 垂直范围；
  - 增加“聚焦当前字幕块”的放大/居中模式；
  - 用 `UIHoverGestureRecognizer` 把注视位置映射到字幕块，画 hover 高亮和名称提示。
- 当前手势：

  - [TimelineTouchInteractionSurface.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Timeline/SubtitleBlocks/TimelineTouchInteractionSurface.swift#L83-L107) 使用 1 指 Pan + 长按 + 单击/双击。
  - 1 指 Pan 在 visionOS 上对应“捏合拖动”，方向/速度需要真机验证。
  - 双击在 visionOS 上是“连续两次捏合”，可用但不够自然；建议把字幕块的双击操作改成 `contextMenu` 或长按菜单。
  - 长按 0.42s 在“捏合并保持”下可用；但要注意手部抖动和系统手势冲突。
- 自绘 Hover 示例：

```swift
let hover = UIHoverGestureRecognizer(target: coordinator, action: #selector(hoverChanged(_:)))
hoverView.addGestureRecognizer(hover)

@objc func hoverChanged(_ recognizer: UIHoverGestureRecognizer) {
    let point = recognizer.location(in: hoverView)
    coordinator.highlightedBlockID = blockAt(point)
}
```

- 60pt 规则来自 Apple 的 visionOS hover 设计指南。标准 Button 有系统自动扩展，自绘字幕块没有，所以必须自己补。

### 4.5 键盘与触觉

- 硬件键盘：当前 [HardwareKeyboardMonitor.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Main/HardwareKeyboardMonitor.swift#L1-L6) 只在 `#if os(iOS)` 生效，visionOS 走空实现（[L233-L241](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Main/HardwareKeyboardMonitor.swift#L233-L241)）。应扩展到 `#if os(iOS) || os(visionOS)`，否则 J/K/L、空格、快捷键在 Vision Pro 上会失效。
- 触觉：visionOS 不提供触觉反馈，系统会用音频反馈替代。当前大量 `UIImpactFeedbackGenerator` 调用（例如 [SubtitleBlocksLayer/Feedback.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Timeline/SubtitleBlocks/SubtitleBlocksLayer/Feedback.swift#L17-L25)、[SlapButtonsOverlay.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Timeline/SlapButtonsOverlay.swift#L80-L87)）在 visionOS 上即使能编译也不会产生触觉。建议集中到 `StropheHaptics`，在 visionOS 上 no-op 或替换成短促音频。
- 虚拟键盘：`TextField` 在 visionOS 上会弹出系统虚拟键盘；文本编辑窗口不要做得过窄，建议最小 600pt 宽，并允许用户把样式/字幕编辑窗口放大。

---

## 5. 视频、字幕与导出

### 5.1 AVPlayerLayer 可用，但只适合平面 2D

`AVPlayerLayer` 在 visionOS 1.0+ 可用，当前原生播放引擎可以在窗口中正常输出 2D 视频。

需要补的细节：

- 在 visionOS 上显式设置 `contentsScale = traitCollection.displayScale`，并在 `traitCollectionDidChange` 时更新。当前 iOS/visionOS 分支没有像 macOS 的 `viewDidChangeBackingProperties` 那样同步 backing scale，窗口在远近变化时可能出现视频发虚。
- 视频窗口用 `.resizeAspect` 或 `.resizeAspectFill` 明确策略；窗口比例变化时字幕覆盖层要跟随视频实际 `videoRect`，不要跟窗口 bounds 走。
- 首版只允许一个视频窗口；多视频输出需要单独验证 `AVPlayer` 多 `AVPlayerLayer` 的行为和性能。

**空间视频/沉浸视频**是另一条路径：

- Apple 建议 3D/空间内容使用 **全窗口 `AVPlayerViewController`**，系统会自动把播放器停靠到理想观看位置。
- visionOS 2/26 的 `AVExperienceController` 提供“扩展/沉浸”体验；visionOS 26 的 `VideoPlayerComponent` 支持 portal/progressive 等模式。
- 这条路径不应该和自定义 SwiftUI 字幕覆盖层混用；沉浸模式下由 AVKit 接管字幕/播放控件。建议放到 P2，作为“审片模式”的增值功能，而不是编辑器主链路。

### 5.2 Metal：窗口内可用，沉浸式另说

- `MTKView` 在 visionOS 1.0+ 可用，窗口内的 Metal 时间线/视频渲染可以继续使用。
- 当前 [MetalSubtitleTimelineView.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Timeline/Metal/MetalSubtitleTimelineView.swift#L160-L162) 用 `traitCollection.displayScale` 计算 `drawableSize`，方向正确；建议增加 `traitCollectionDidChange` / `layoutSubviews` 双重同步，以适配窗口远近缩放。
- `preferredFramesPerSecond = 120`（L81）在 90Hz 的 Vision Pro 上不会变成 120Hz；时间线本身是暂停 + `setNeedsDisplay`，影响不大，但不要为 120 做性能假设。
- 沉浸式空间的自绘 Metal 不能用 `MTKView`，要用 `CompositorServices` + `CompositorLayer`；这与本次“多窗口编辑器”无关，放到 P2。
- `rgba16Float` 渲染目标在 visionOS 窗口中的 EDR/HDR 行为需要真机验证；如果颜色发灰或过曝，先退回 `bgra8Unorm`，再评估 HDR。

### 5.3 FFmpeg 与构建

- xcframework 已有 `xros-arm64` / `xros-arm64-simulator`，Apple Silicon 上可编译。
- 没有 `x86_64` 模拟器切片，Intel Mac / 通用模拟器构建会链接失败；CI 固定 Apple Silicon，或补切片。
- visionOS 真机解码性能、4K/HEVC/AV1 的 VideoToolbox 路径要用真机测；模拟器不能代表 M2/R1 的实际表现。

### 5.4 导出：当前在 visionOS 上是断的（P0）

[MainContentView.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Main/MainContentView.swift#L250-L269) 把 `fileExporter` 包在 `#if os(iOS)` 里：

```swift
#if os(iOS)
    .fileExporter(...)   // 内嵌字幕导出
    .fileExporter(...)   // 硬字幕导出
#endif
```

而 [L276-L280](file:///Volumes/KIOXIA/code/Strophe/Strophe/Views/Main/MainContentView.swift#L276-L280) 在非 macOS 上只是把 `isShowingHardSubtitleExport = true`。visionOS 会走到这个分支，但没有挂 `fileExporter`，结果就是**点导出没有反应**。

修复：

```swift
#if os(iOS) || os(visionOS)
    .fileExporter(...)
    .fileExporter(...)
#endif
```

同时确认：

- `UTType.stropheMatroskaVideo` / 硬字幕容器类型在 visionOS 上可用；
- 导出目标用 Files 的 security-scoped URL，和 iOS 一样处理 `startAccessingSecurityScopedResource()`；
- 导出进度面板在主窗口或独立窗口内都能显示，不要依赖模态 sheet 的窗口层级。

### 5.5 字幕

- 平面视频窗口内的 SwiftUI 字幕覆盖层可以保留；它跟随视频窗口尺寸变化即可。
- 独立“字幕预览/提词”窗口只读当前字幕，适合审片、配音、导演监看；不要让它持有播放器。
- 样式窗口修改 `StyleAndGroupStore` 后，视频窗口和时间线应实时刷新；这需要把样式窗口的编辑状态从“sheet 本地 @State”改成“共享 store + 可撤销的编辑事务”。

---

## 6. 数据、状态与生命周期

### 6.1 共享模型

- `SubtitleProject` 继续由 App 级持有，所有 Scene 共享。
- 每个窗口的局部状态用 `@State` / `@SceneStorage`：
  - 时间线滚动位置、缩放级别；
  - 字幕列表滚动位置；
  - 样式窗口当前 tab；
  - 视频窗口是否显示安全框。
- 不要把“当前选中字幕”做成每个窗口独立的 `@State`；它应该属于工程级共享状态，这样在时间线点一句，视频窗口和主窗口同时高亮。

### 6.2 自动保存与“随时被关闭”

Vision Pro 用户可能随时把窗口放到一边、切换房间、关闭 App。当前自动保存是 30 秒定时器，并且只有存在 `projectURL` 时才写盘：

- [Persistence.swift](file:///Volumes/KIOXIA/code/Strophe/Strophe/Models/Subtitle/SubtitleProject/Persistence.swift#L638-L684)：`startAutoSave()` 30s；`performAutoSave()` 里 `guard isDirty, let url = projectURL else { return }`。

风险：**新建但还没保存过路径的工程，在 visionOS 上被关闭时可能丢失编辑**。

建议：

1. 在 `scenePhase` 进入 `.background` / `.inactive` 时主动调用一次保存（有 `projectURL` 时）。
2. 对没有 `projectURL` 的新工程，写入 Application Support 的恢复快照，并在下次启动时提示恢复（现有 `ProjectRecoveryView` 可以复用/扩展）。
3. 如果用户主动关闭窗口，在视频/时间线 Scene 的 `onDisappear` 里停止播放、释放临时资源，但不要销毁共享 `project`。
4. 自动保存失败要给可见提示，不能只 `print`。

### 6.3 场景恢复

- 默认 `.restorationBehavior(.automatic)`：窗口会按平台默认恢复；visionOS 会恢复用户上次的尺寸/位置。
- 对“临时工具窗口”（例如导出进度、一次性提示）用 `.restorationBehavior(.disabled)`，避免下次启动冒出无用窗口。
- 对视频/时间线/样式窗口，**保留恢复**：用户把工作台摆好、锁定到墙面后，希望下次回来还在。
- visionOS 26+ 才有的 `.defaultLaunchBehavior(.suppressed)` 用于抑制次要窗口在无历史状态时自动出现；用 `if #available(visionOS 26.0, *)` 包住。
- 样式窗口按 `UUID` 恢复；如果对应样式已删除，窗口应显示空状态并自动 `dismissWindow`。

---

## 7. 实施计划

### P0：先让“拆分”真正可用

| 项 | 改动 | 验收 |
|---|---|---|
| 多 Scene 骨架 | `StropheApp.swift` 增加 Editor/Video/Timeline/Subtitle/Style 五个 Scene；引入 `SpatialWorkspaceModel` | 能独立打开/关闭每个窗口 |
| 视频单一宿主 | 主窗口在视频窗口打开时显示占位；关闭后恢复内嵌；`PlayerEngine` host view 重新挂载 | 不黑屏、不双播放器、不崩溃 |
| 原生 Tab Bar | `StropheSidebarContainer` / `StropheTabBar` 在 visionOS 走 `TabView` | Tab Bar 在窗口前缘竖直出现，注视展开 |
| 窗口外观 | visionOS 去掉不透明根背景和侧栏叠加 material；保留系统玻璃；顶部留窗口栏空间 | 窗口像系统窗口，不是“深色卡片” |
| 导出修复 | `MainContentView` 的 `fileExporter` 扩展到 visionOS | 软字幕/硬字幕/内嵌字幕能导出到 Files |
| 时间线可用性 | 字幕块 hover 高亮、60pt 命中扩展、双击改菜单、1 指 Pan 真机验证 | 眼动+捏合能选中/拖动/分割 |
| 生命周期 | `scenePhase` 保存；新工程恢复快照；关闭窗口复位 workspace 标志 | 关闭/重启不丢编辑、不出现幽灵窗口 |

### P1：把空间工作台做顺

| 项 | 改动 |
|---|---|
| 布局预设 | “聚合 / 审片 / 工作台 / 样式实验室”四个按钮；首次打开用 `defaultWindowPlacement`，之后尊重用户位置 |
| 样式多开 | `WindowGroup(for: UUID.self)` + `utilityPanel`；实时应用 + 撤销；删除样式自动关窗 |
| 字幕提词窗口 | 只读大字幕、当前句/下一句、可调字号/背景 |
| Ornament 工具栏 | 视频播放控制、时间线高频操作放底部 Ornament；低频操作进 Menu |
| 键盘 | `HardwareKeyboardMonitor` 支持 visionOS；Ornament 按钮加 `.keyboardShortcut` |
| 音频 | 验证 `AVAudioSession` 在 visionOS 的行为；必要时把 `StropheAudioSession` 扩展到 visionOS |
| 触觉抽象 | 集中 `StropheHaptics`，visionOS no-op / 音频反馈 |
| 文本与命中 | 时间线字号、块命中区、样式面板最小宽度按 visionOS 调整 |
| Metal 细节 | `traitCollectionDidChange` 同步 drawable；90Hz/EDR 真机验证 |

### P2：空间媒体能力

| 项 | 改动 | 说明 |
|---|---|---|
| 空间视频审片 | `AVPlayerViewController` 全窗口播放；`AVExperienceController` / `VideoPlayerComponent` | 与编辑器分离，作为“影院模式”；自定义字幕覆盖层不进入沉浸模式 |
| Volume 工作台 | 3D 面板/RealityKit `ViewAttachmentComponent` | 仅实验；Volume 固定尺寸，不适合主力编辑 |
| Immersive Space | 大屏/环境背景 | 系统同一时间只允许一个；文本输入和窗口管理复杂，不建议作为主链路 |

### 实施状态（2026-10-28）

P0 / P1 / P2 已按上表落地，编译通过（visionOS 27.2 模拟器、iOS 17 模拟器、macOS）。关键落地位置：

| 级别 | 状态 | 代码位置 |
|---|---|---|
| P0 多 Scene | 已完成 | [StropheApp.swift](Strophe/App/StropheApp.swift)、[SpatialWorkspaceModel.swift](Strophe/Views/Spatial/SpatialWorkspaceModel.swift)、[SpatialSceneRoots.swift](Strophe/Views/Spatial/SpatialSceneRoots.swift) |
| P0 视频单一宿主 | 已完成 | [MainContentView.swift](Strophe/Views/Main/MainContentView.swift) 的 `videoSurface` 与时间线占位、[VideoPlayerView.swift](Strophe/Views/VideoPlayer/VideoPlayerView.swift) 的 `suspendsPlaybackOnDisappear` |
| P0 原生 Tab Bar | 已完成 | [Layouts.swift](Strophe/Views/Main/ContentView/Layouts.swift) 的 `visionOSWideLayout`、[StropheSidebarContainer.swift](Strophe/Views/Sidebar/StropheSidebarContainer.swift) |
| P0 窗口外观 | 已完成 | [WelcomeView.swift](Strophe/Views/Welcome/WelcomeView.swift)、[StyleEditSheet.swift](Strophe/Views/Style/StyleEditSheet.swift) 的 visionOS 透明背景分支 |
| P0 导出修复 | 已完成 | [MainContentView.swift](Strophe/Views/Main/MainContentView.swift) 的 `fileExporter` 条件改为 `os(iOS) \|\| os(visionOS)` |
| P0 时间线可用性 | 已完成（待真机手势验证） | [HitTesting.swift](Strophe/Views/Timeline/SubtitleBlocks/SubtitleBlocksLayer/HitTesting.swift) 的 `fingerVerticalTouchSlop`、[TimelineTouchInteractionSurface.swift](Strophe/Views/Timeline/SubtitleBlocks/TimelineTouchInteractionSurface.swift) 的 `UIHoverGestureRecognizer` |
| P0 生命周期 | 已完成 | [Persistence.swift](Strophe/Models/Subtitle/SubtitleProject/Persistence.swift) 的 `saveScenePhaseSnapshot()`、[ContentView.swift](Strophe/Views/Main/ContentView.swift) 的 `scenePhase` 监听 |
| P1 布局预设 / 提词 / Ornament | 已完成 | [SpatialLayoutMenu.swift](Strophe/Views/Spatial/SpatialLayoutMenu.swift)、`SpatialSceneRoots.swift` 各窗口的 `bottomOrnament` |
| P1 样式多开 | 已完成（实时应用，无撤销栈） | [StyleWindowRoot](Strophe/Views/Spatial/SpatialSceneRoots.swift)、[StyleEditSheet/Actions.swift](Strophe/Views/Style/StyleEditSheet/Actions.swift) 的 `saveStyleDraft()` |
| P1 键盘 / 音频 / Haptics / Metal | 已完成 | [HardwareKeyboardMonitor.swift](Strophe/Views/Main/HardwareKeyboardMonitor.swift)、[StropheHaptics.swift](Strophe/Support/StropheHaptics.swift)、[MetalSubtitleTimelineView.swift](Strophe/Views/Timeline/Metal/MetalSubtitleTimelineView.swift)、[MetalTimelineTextAtlas.swift](Strophe/Views/Timeline/Metal/MetalTimelineTextAtlas.swift) |
| P2 影院 / Volume / 沉浸 | 已完成（实验性） | `CinemaWindowRoot`、`VolumePreviewRoot`、`ImmersiveCinemaView`（`SpatialSceneRoots.swift`） |

实施中的两点偏差：

1. **单实例窗口降级。** SwiftUI 的 `Window`（单实例 Scene）要求 visionOS 26+，而工程部署目标是 visionOS 2.0，因此统一使用带 id 的 `WindowGroup`；菜单按钮改为“已开则关、未开则开”，避免重复窗口。升级部署目标到 26.0 后可换回 `Window`。
2. **样式窗口不提供撤销栈。** 实时应用直接写回 `StyleAndGroupStore`，只在窗口内保留 Done；样式被删除时窗口自动关闭。撤销需要改造 store 的写入模型，未纳入本次范围。

仍未验证（需要 Apple Vision Pro 真机）：眼动 hover 的实际高亮强度、60pt 命中体感、90Hz/EDR 下的 Metal 表现、窗口吸附墙面与跨房间位置保持。

### 非目标

- 不做窗口内任意拖拽的“自由画布”；
- 不做自定义窗口边框/关闭按钮；
- 不做窗口旋转/倾斜；
- 不做“始终置顶”的样式面板；
- 不做多个视频窗口同时输出（除非验证通过）；
- 不重写 Metal 时间线渲染器。

---

## 8. 验收矩阵

### 8.1 功能

- [ ] 打开工程，主窗口正常显示侧栏、视频、时间线。
- [ ] 打开视频窗口，主窗口视频区域变为占位；视频在独立窗口播放，音频正常。
- [ ] 打开时间线窗口，选中句在视频/主窗口/时间线三处同步。
- [ ] 打开两个不同样式的窗口，修改样式 A，视频字幕实时变化；样式 B 不受影响。
- [ ] 打开字幕提词窗口，当前句/下一句随播放更新。
- [ ] 关闭视频窗口，主窗口恢复内嵌视频，不黑屏。
- [ ] 关闭样式窗口，重新打开同一 `UUID` 回到原窗口；删除样式后窗口自动关闭。
- [ ] 软字幕、硬字幕、内嵌字幕在 visionOS 上都能导出到 Files。

### 8.2 空间行为

- [ ] 每个窗口都能被用户拖动、缩放；缩到最小时控件不裁切。
- [ ] 首次打开按默认位置出现；用户移动后，关闭再开恢复用户位置。
- [ ] 重启 App，视频/时间线/样式窗口按上次状态恢复；不出现重复窗口。
- [ ] visionOS 26 真机：窗口可吸附到墙面并锁定；换房间/重启后位置保持。
- [ ] 样式窗口与视频窗口并排时，视频不被永久遮挡；没有“置顶”假设。

### 8.3 输入与可访问性

- [ ] 眼动+捏合能选中字幕块、拖动、分割、合并。
- [ ] 字幕块有 hover 高亮；60pt 命中规则生效。
- [ ] 双击操作有菜单替代路径；长按菜单可用。
- [ ] 硬件键盘 J/K/L、空格、方向键可用。
- [ ] 虚拟键盘能编辑字幕文本，窗口最小宽度下不挤压。
- [ ] VoiceOver / 动态字体 / 减少透明度下无布局崩溃。
- [ ] visionOS 上无触觉调用报错/卡顿。

### 8.4 性能

- [ ] 4K 视频 + 5000 条字幕 + 两个窗口同时播放/滚动，帧率稳定。
- [ ] 时间线在 90Hz 下没有持续满帧重绘；暂停时 `MTKView` 不空转。
- [ ] 多窗口下内存无明显泄漏；关闭窗口后播放器/时间线资源释放。
- [ ] 模拟器与真机分别记录：启动时间、窗口打开时间、播放 CPU/GPU、内存峰值。

---

## 9. 风险与未决问题

1. **窗口控制权在用户手里。** App 不能把窗口“摆”到指定位置；只能给初始 placement。产品文案不要承诺“自动排列”。
2. **视频宿主唯一性。** 如果后续要支持“主窗口小窗预览 + 独立大屏同时播放”，需要先改造 `PlayerEngine` 为多宿主，或使用两个独立 `AVPlayer`；这会带来音画同步和性能问题，建议留到 P2。
3. **时间线是最大交互风险。** 28pt 高的 Metal 字幕块 + 眼动瞄准 + 无触觉，需要真机反复调；不能只靠模拟器。
4. **HDR/EDR 不确定。** `rgba16Float` 在 visionOS 窗口中的表现要真机验证；不要在没测之前把 HDR 当卖点。
5. **2.0 与 26 的 API 差异。** `defaultWindowPlacement` / `utilityPanel` / `bottomOrnament` 在 2.0 可用；`defaultLaunchBehavior` 是 26.0+；`restorationBehavior` 是 2.0+。所有 26+ API 都要 `if #available`。
6. **App Store 与分发。** 原生 visionOS 构建需要 visionOS 截图/图标/隐私说明；`SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = NO` 表示不是“Designed for iPad”，要按原生 visionOS 应用准备素材。
7. **多工程未决。** 当前单 `project` 实例决定了编辑器不能真正多开；如果未来要做“多工程并排”，需要 `DocumentGroup` 或每个窗口独立 `SubtitleProject`。

---

## 10. 参考资料

- Apple HIG：Windows — https://developer.apple.com/design/human-interface-guidelines/windows
- Apple HIG：Spatial layout — https://developer.apple.com/design/human-interface-guidelines/spatial-layout
- Apple HIG：Tab bars — https://developer.apple.com/design/human-interface-guidelines/tab-bars
- Positioning and sizing windows — https://developer.apple.com/documentation/visionos/positioning-and-sizing-windows
- `defaultWindowPlacement(_:)` — https://developer.apple.com/documentation/swiftui/scene/defaultwindowplacement(_:)
- `WindowPlacement.Position`（含 `utilityPanel` / `below` / `trailing`）— https://developer.apple.com/documentation/swiftui/windowplacement/position
- `WindowResizability` — https://developer.apple.com/documentation/swiftui/windowresizability
- Handling the window life cycle with multiple scenes — https://developer.apple.com/documentation/visionos/handling-the-window-life-cycle-with-multiple-scenes
- Adopting best practices for persistent UI（窗口吸附/锁定/持久化）— https://developer.apple.com/documentation/visionos/adopting-best-practices-for-scene-restoration
- `WindowGroup.init(_:id:for:content:)` — https://developer.apple.com/documentation/swiftui/windowgroup/init(_:id:for:content:)
- `AVPlayerLayer`（visionOS 1.0+）— https://developer.apple.com/documentation/avfoundation/avplayerlayer
- `MTKView`（visionOS 1.0+）— https://developer.apple.com/documentation/metalkit/mtkview
- Determining whether to bring your app to visionOS（触觉/多指手势差异）— https://developer.apple.com/documentation/visionos/determining-whether-to-bring-your-app-to-visionos
- WWDC25：Set the scene with SwiftUI in visionOS — https://developer.apple.com/videos/play/wwdc2025/290/
- WWDC25：Support immersive video playback in visionOS apps — https://developer.apple.com/videos/play/wwdc2025/296/
- WWDC25：Design hover interactions for visionOS（60pt 目标）— https://developer.apple.com/videos/play/wwdc2025/303/
- Immersive media overview（AVExperienceController 等）— https://developer.apple.com/documentation/technologyoverviews/immersive-media
- Immersive spaces（同一时间一个空间）— https://developer.apple.com/documentation/swiftui/immersive-spaces
