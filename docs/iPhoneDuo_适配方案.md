# Strophe 的 iPhone Duo 适配方案

> 本文只做分析与方案，没有改动任何 Swift 代码。
> 依据：Apple《Prepare your app for iPhone Duo》、《Designing for iPhone Duo》(HIG) 与 WWDC 技术讲座《Prepare your app for iPhone Duo》。

## 0. 结论

- 当前工程由 Xcode 27.2 构建，使用 iOS 27.2 SDK，已经处于 Apple 所说的「iOS 27.1 SDK 及以后」完整适配档位；`IPHONEOS_DEPLOYMENT_TARGET = 16.0` 不阻碍 Duo 适配，SDK 版本才是关键。
- 工程同时支持 iPhone / iPad（`TARGETED_DEVICE_FAMILY = "1,2"`）。Duo 内屏是 Regular Width，Strophe 会走 `wideLayout`（`NavigationSplitView`），方向与 Apple 的建议一致：内屏应当是 iPad 布局的自然延伸，而不是另一套折叠屏 UI。
- 不需要为每种折叠姿态重写界面。重点是把 4 个 P0 风险处理掉，再按 P1 清单逐项验证。
- 播放器与 Metal 渲染的基础是对的：`PlayerEngine` 使用 `.resizeAspect`，不会为了填满屏幕裁掉画面；`MTKView` 的 drawable 跟随视图尺寸。需要验证的是折叠后的坐标与状态，而不是重写渲染。

### SDK 档位对照

| 构建 SDK | 在 iPhone Duo 上的表现 |
| --- | --- |
| iOS 26 SDK 及更早 | 能运行；展开后 App 居中，四周留白，外屏可能受状态栏/相机区域影响 |
| iOS 27 SDK | 会随折叠/展开调整尺寸，内屏只用大部分区域，仍避开右边缘状态栏 |
| iOS 27.1 SDK 及以后 | 可延伸到屏幕边缘；工具栏 / Tab Bar 在需要时竖排在状态栏下方，是完整适配目标 |

## 1. P0：上线前必须处理

### 1.1 iPhone 端仍然锁定竖屏

- 位置：`Strophe.xcodeproj/project.pbxproj:524-525`、`591-592`
- 现状：`INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait`，只有 iPad 允许四方向。
- 风险：Duo 在手机 idiom 下运行。内屏横屏姿态或半折叠姿态下，竖屏锁定可能让窗口仍按竖屏比例布局，无法用满内屏；外屏与内屏切换时也可能触发不必要的旋转/重建。
- 建议：把 iPhone 的支持方向放开到四方向（至少 Portrait + LandscapeLeft + LandscapeRight），然后用 Duo 模拟器验证折叠/展开、旋转和半折叠。布局判断不要改成读方向，仍然按可用宽高和 Size Class 决定。

### 1.2 折叠时 wide / compact 直接换视图树，瞬态状态会丢

- 位置：`Strophe/Views/Main/ContentView.swift:89-97`
- 现状：`sizeClass == .compact ? compactLayout : wideLayout`，两套布局各自创建 `MainContentView`。
- 风险：Duo 折叠/展开会改变 Size Class，SwiftUI 会销毁一棵视图树、重建另一棵。`project` 里的工程数据和 `PlayerEngine` 的播放位置能保留，但 `MainContentView` 内部的 `@State`（导出设置、sheet 开关、临时选择等，见 `MainContentView.swift:16-32`）以及时间线视图的 Coordinator 状态（缩放、滚动位置）会被重置。用户会感觉「展开后像重新打开了 App」。
- 建议：保留一个容器，用 `NavigationSplitView` 的 `columnVisibility` 随可用宽度切换 `.all` / `.detailOnly`，而不是在 compact / wide 两棵树之间切换；或把时间线缩放、滚动、正在编辑的字幕块等瞬态状态提升到 `SubtitleProject` / 专门的状态对象。验收标准：折叠再展开后，播放位置、当前字幕块、时间线缩放与滚动都保持。

### 1.3 侧栏忽略安全区，并用 idiom 写死顶部间距

- 位置：`Strophe/Views/Main/ContentView/Layouts.swift:20`、`Strophe/Views/Sidebar/StropheSidebarContainer.swift:95`
- 现状：侧栏 `.ignoresSafeArea(.container, edges: [.top, .bottom])`，内容顶部按 `userInterfaceIdiom == .pad ? 72 : 16` 手动留白。
- 风险：Duo 外屏以及内屏横屏时，系统会把状态栏、工具栏、Tab Bar 放到侧边，左右安全区还可能不对称（分屏时两个 App 各占一侧）。固定 72/16 与忽略安全区会让侧栏内容压到系统栏或外屏相机保留区下面。
- 建议：背景可以继续延伸到安全区之外，但控件与文字必须遵守 `safeAreaInsets`。用 `GeometryReader` 读取安全区，或使用 `safeAreaInset` / `ReservedRegion`（iOS 27.1+）给自定义画布留位；删除基于 idiom 的固定 padding。测试重点：外屏、内屏横屏、左右分屏各一次。

### 1.4 自定义 Tab Bar 不会像系统 TabView 那样自动移到侧边

- 位置：`Strophe/Views/Navigation/StropheTabBar.swift:52-57`、`Strophe/Views/Sidebar/StropheSidebarContainer.swift:47-67`
- 现状：Strophe 自己绘制 tab bar，并放在侧栏底部；`isDesktop` 直接用 `horizontalSizeClass == .regular` 判断。
- 风险：Apple 只保证标准 `TabView` / `UITabBarController` 在 Duo 外屏和内屏横屏时自动竖排到侧边。自定义 bar 会继续待在底部，和外屏相机、侧边状态栏的组合可能出现遮挡或触控区域不顺手；`regular == iPad` 的假设在 Duo 和可调整窗口的 iPhone Mirroring 上也不再成立。
- 建议：优先评估 iOS 27.1 上改用标准 `TabView`（外观可用 `tabViewStyle` / 自定义 item 保持现有视觉）；如果必须保留自绘 bar，至少按「可用宽度 + 安全区」决定横排/竖排，并为侧边放置留出 reserved region。命名与判断也从 `isDesktop` 改成明确的布局状态（如 `usesWideChrome`）。

## 2. P1：建议一起做

### 2.1 侧栏宽度写死 300

- 位置：`Layouts.swift:19` `.navigationSplitViewColumnWidth(300)`
- 内屏分屏或较窄窗口下，固定 300 会挤压详情列。改成 `min: 260, ideal: 300, max: 360`，让 Split View 在折叠/分屏时自行收缩。

### 2.2 Regular Width 不再等于 iPad

- 位置：`StropheTabBar.swift:56`；`ContentView.swift:39`
- Duo 内屏、iPhone Mirroring 的可调整窗口都可能给出 Regular Width。凡是「Regular 就启用 iPad 专属逻辑」的分支都要改成基于可用空间阈值的显式策略，避免在手机上误开 iPad 布局或反向漏开。

### 2.3 idiom 驱动的尺寸

- 位置：`Strophe/Views/Timeline/SlapButtonsOverlay.swift:17-38`、`StropheSidebarContainer.swift:95`
- `userInterfaceIdiom == .pad` 在 Duo 上仍然是 `.phone`。按钮宽度、边距应改成由可用宽度 / Size Class 决定，而不是 idiom。

### 2.4 不要依赖 `UIScreen.main` 的缩放

- 位置：`Strophe/Views/Timeline/Metal/MetalSubtitleTimelineView.swift:159`
- 现状：`window?.screen.scale ?? UIScreen.main.scale`。
- 建议：优先 `traitCollection.displayScale`（UIKit）或 `@Environment(\.displayScale)`（SwiftUI），不要缓存 `UIScreen`。该视图已经在 `layoutSubviews` 里按 bounds 重建 Metal drawable，这一点保留；折叠后重点验证时间线刻度、命中区域和播放头坐标是否仍按新宽度计算。

### 2.5 视频与自绘画布的裁切/坐标

- `Strophe/Models/PlayerEngine.swift:116` 使用 `.resizeAspect`，视频不会被裁切，符合 Apple 对全幅媒体的建议；保持。
- `CustomAVPlayerView.swift:22,46` 使用 `.resizeAspectFill`，但当前没有被工程引用，可忽略或后续清理，避免以后误用。
- `MetalVideoRenderer` 是 `MTKView` 子类，drawable 默认跟随视图 bounds 与屏幕缩放；需要验证折叠后 `drawableSize`、字幕叠加层坐标、时间线刻度三者一致。
- 检查所有 `.ignoresSafeArea`：背景/视频可以延伸到安全区，文字、按钮、字幕编辑控件不能。

### 2.6 工具栏顺序与可用性

- 系统 `.toolbar` 在 Duo 上会竖排。按 HIG：顶部留给返回/关闭，然后是主要动作（完成），其余保持原有分组；优先 `ToolbarItemGroup`，图标用 SF Symbols，文字按钮同时给图标与标题，方便系统收进溢出菜单。
- 重点检查 `StropheMainToolbar`、`StropheSidebarToolbar` 的 placement 在竖排后是否仍然合理；`StropheNavBarCommands.swift:351-370` 的 compact 分支也要在 Duo 内屏（Regular）和外屏（Compact）各验证一次。

### 2.7 分屏与安全区不对称

- Duo 内屏可以左右分屏，两个 App 的控件分别贴各自外侧边。侧栏与详情列都要能接受左右不对称的安全区；不要用对称 padding 硬扛。
- 现有的 compact 布局大量使用 `.ignoresSafeArea`（`Layouts.swift:71,78`），要逐个确认只作用在背景层。

## 3. 建议的验收矩阵

| 场景 | 关注点 |
| --- | --- |
| 外屏（折叠） | 单列布局、底部/侧边 Tab Bar、状态栏与外屏相机区域不遮挡 |
| 内屏竖屏 | Regular Width 是否正确进入 wideLayout；系统横排工具栏是否正常 |
| 内屏横屏 | 工具栏/Tab Bar 竖排到侧边；侧栏安全区；详情列宽度 |
| 半折叠 | 铰链附近是否有内容被遮；是否需要 `ReservedRegion`（进阶） |
| 折叠 ↔ 展开 | 播放位置、当前字幕块、时间线缩放/滚动、正在编辑的文本是否连续 |
| 左右分屏 | 两侧 App 的控件是否各贴外边缘；不对称安全区 |
| 极端窗口 | Device Hub 可调整尺寸模拟器 + macOS 27 iPhone Mirroring，宽高双向拉到极端 |
| 回归 | 按钮是否被遮挡、文字是否裁切、视频是否被裁、触摸/字幕块命中是否偏移 |

测试工具：Xcode 27.1/27.2 的 iPhone Duo 模拟器、Device Hub 的可调整尺寸模拟器、macOS 27 的 iPhone Mirroring。

## 4. Apple 工具与发布

- 在 Xcode 编码助手里执行「get my app ready for iPhone Duo」，或终端 `xcrun agent skills export` 导出 App Resizability skill。它能扫出大部分 `UIScreen.main`、方向、idiom、固定尺寸问题，但不能代替模拟器实测。
- 始终用 iOS 27.1 及以后 SDK 构建，才能进入完整适配档位。
- 发布阶段：App Store Connect 提交 Duo 截图可获得适配 badge；可用新的预览工具检查素材；支持全部姿态后可提交 featuring nomination。

## 5. 改动优先级清单

| 优先级 | 文件 | 改动 |
| --- | --- | --- |
| P0 | `Strophe.xcodeproj/project.pbxproj` | iPhone 方向由仅竖屏改为支持全部方向，并验证 Duo 姿态 |
| P0 | `Strophe/Views/Main/ContentView.swift` | 不再在 compact / wide 两棵树之间切换；改用单一容器 + columnVisibility 或提升瞬态状态 |
| P0 | `Layouts.swift` / `StropheSidebarContainer.swift` | 去掉侧栏 `.ignoresSafeArea` 与 idiom 固定 padding，改为安全区驱动 |
| P0 | `StropheTabBar.swift` | 评估改用标准 TabView，或让自绘 bar 支持侧边放置与 reserved region |
| P1 | `Layouts.swift` | 侧栏宽度改为 min / ideal / max |
| P1 | `StropheTabBar.swift` | `isDesktop` 改为基于可用宽度的布局状态，不再等同 iPad |
| P1 | `SlapButtonsOverlay.swift` | 按钮尺寸/边距由可用宽度决定 |
| P1 | `MetalSubtitleTimelineView.swift` | 缩放改用 traitCollection.displayScale，验证折叠后坐标 |
| P1 | `MetalVideoRenderer.swift` / 视频叠加层 | 验证 drawable、字幕坐标、时间线刻度在折叠后一致 |
| P2 | `CustomAVPlayerView.swift` | 未被引用；清理或改回 `.resizeAspect` 防止误用 |
| P2 | 工具栏相关文件 | 验证竖排工具栏顺序、图标与溢出菜单 |

## 6. 非目标

- 不为每种折叠姿态单独设计一套界面。
- 不把「宽度变成 Regular」直接等同于「切换到 iPad 专属界面」。
- 不通过监听设备方向来决定布局；一律以实际可用宽高与 Size Class 为准。
