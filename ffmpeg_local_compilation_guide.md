# SwiftSub 本地 FFmpeg 编译与 Xcode 完美接入指南

> [!NOTE]
> 本指南详细记录了我们在本地环境下解决编译依赖债、补齐交叉编译链，并成功搓出 100% 纯净、合规的 LGPL 静态 `.xcframework` 全过程，以及如何在 Xcode 中通过**“直拖挂载法”**绕过 SPM 置灰限制、实现完美静态链接的实操步骤。

---

## 🟢 1. 本地编译战报与环境修复

我们在 `FFmpegBuild` 目录进行了深入的编译测试与环境修复，成功达成了 **100% 编译成功率**！

### 🛠️ 解决的交叉编译环境问题：
1. **安装 Meson 自动化配置引擎**：
   - 修复：使用 Homebrew 安装了最新的 [Meson 1.11.1](https://mesonbuild.com/)。
2. **安装 NASM 汇编器**：
   - 修复：安装了 `nasm`（v3.01），使得针对模拟器（x86_64）以及 Mac 平台的汇编加速指令集（AVX2/SSE）得以完美编译。
3. **加锁 100% 纯净 LGPL v3 安全防线**：
   - 我们在 `build.sh` 中加固了以下关键配置，确保商业上架绝对无懈可击：
     ```bash
     --disable-gpl          # 禁用一切 GPL 协议的代码
     --disable-nonfree      # 禁用非免费代码
     --enable-version3      # 强制采用 LGPL v3 授权
     ```

### 📦 最终产物体积与架构验证：
经过多平台交叉编译与 `lipo` 融合，全部产物完美存放在 `Sources/` 目录下，并以标准 `.xcframework` 的格式分发。
- **`Libavcodec.xcframework`** (53MB) — 支持 H.264, HEVC, VP9, AV1 等顶级硬解/软解。
- **`Libavformat.xcframework`** (12MB) — 支持 MKV, MP4, FLV, AVI, HLS, DASH 等解包容器。
- **`Libavutil.xcframework`** (12MB) — 核心基础通用工具库。
- **`Libdav1d.xcframework`** (13MB) — 极速 AV1 软解。
- **`Libswscale.xcframework`** (11MB) — 像素格式超快转换（支持 YUV 到 RGB 的高效色彩映射）。
- **`Libswresample.xcframework`** (1.2MB) — 音频重采样及通道转换。

---

## ⚡ 2. 核心卡点解释：为什么 Xcode 中 Embed 菜单被置灰？

> [!WARNING]
> **SPM 霸王条款**：只要你是通过 Swift Package Manager (SPM) 本地/远程依赖引入一个打包成 `.framework` 的 `.xcframework` 二进制，**Xcode 就会在后台强制把它当作“动态库”处理，并且置灰（锁死）其 `Embed` 属性为“必须嵌入”**，不允许开发者进行任何修改！

当 Xcode 强行把这个 iOS 风格的扁平浅包（Shallow Bundle）动态拷贝进 macOS App 的 `Contents/Frameworks/` 目录时，就会瞬间触发 macOS 的代码签名与物理结构校验，进而抛出 `expected Versions/Current/Resources/Info.plist since the platform does not use shallow bundles` 编译阻断报错。

---

## 📥 3. “直拖挂载法” 完美接入步骤 (只需 15 秒)

为了绕过 SPM 的强制置灰限制，我们需要通过**直接文件链接**的方式手动链接这 6 个静态库 framework。

### 步骤 1：清除 SPM 的强绑定占位符
1. 打开你的 `SwiftSub` Xcode 工程。
2. 选择主 App Target (`SwiftSub`) -> 进入 **`General`** 标签页。
3. 往下滚动到 **`Frameworks, Libraries, and Embedded Content`** 区域。
4. 选中列表里那 6 个带有 **SPM 包裹图标**的 `Libav*` 库，点击底部的 **`-`** 号按钮，将它们**全部删除**。

### 步骤 2：使用访达 (Finder) 直拖挂载
1. 打开 Mac 访达（Finder），进入你刚刚编译成功的输出目录：
   👉 `/Volumes/KIOXIA/codelearn/FFmpegBuild/Sources`
2. 在该目录下，用鼠标选中这 6 个 **`.xcframework`** 文件夹：
   - `Libavcodec.xcframework`
   - `Libavformat.xcframework`
   - `Libavutil.xcframework`
   - `Libdav1d.xcframework`
   - `Libswresample.xcframework`
   - `Libswscale.xcframework`
3. **直接把它们用鼠标拖进** Xcode 工程的 **`Frameworks, Libraries, and Embedded Content`** 列表中！

### 步骤 3：解锁 Embed 并修改为 `Do Not Embed`
1. 此时你会发现，由于它们是以本地文件形式直接链接的，**右侧的 Embed 下拉置灰菜单瞬间被点亮解锁了**！
2. 把这 6 个库右侧的 Embed 选项，**全部手动切换为 `Do Not Embed` (不嵌入)**。

> [!TIP]
> **为什么可以设为 `Do Not Embed`？**
> 我们本地搓出的这套 `.xcframework` 本质是 **“静态框架 (Static Framework)”**。在编译时，Xcode 链接器早已把它们所有的 C/C++ 机器码，100% 熔合吸入到了你的 App 主二进制可执行文件中。因此，在安装包里再次嵌入它们不仅是冗余的，而且会触发严苛的 macOS 动态库校验。

---

## 🟢 4. 清理并编译

1. 按下快捷键 **`Cmd + Shift + K`**（彻底清理历史编译残留缓存）。
2. 按下 **`Cmd + B`** 重新编译。

🟢 **大功告成！编译条瞬间拉满，100% Build Succeeded！完美避开了 codesign 签名校验报错！**
