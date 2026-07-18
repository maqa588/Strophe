# Strophe 本地 FFmpeg 编译与 Xcode 接入指南

本项目使用 `/Users/maqa/codelearn/FFmpegBuild` 生成一组精简的动态
`.xcframework`。当前配置只保留 Strophe 实际使用的五个 FFmpeg 库和
dav1d，不编译 libavfilter、zimg、libzvbi，也不包含 GPL、LGPLv3 或
nonfree 组件。

## 1. 构建范围

只生成以下六个产物：

- `Libavcodec.xcframework`：音视频解码。
- `Libavformat.xcframework`：容器解析、读取和 seek。
- `Libavutil.xcframework`：frame、buffer、option 等基础 API。
- `Libswresample.xcframework`：音频重采样和声道转换。
- `Libswscale.xcframework`：视频像素格式转换。
- `Libdav1d.xcframework`：AV1 软件解码回退。

只构建三个架构目标：

- iOS device arm64，最低 iOS 16。
- macOS arm64，最低 macOS 13。
- macOS x86_64，最低 macOS 13。

不生成 iOS Simulator、tvOS、libavfilter、zimg 或 libzvbi 产物。DVB
Teletext 解码随 libzvbi 一起移除；Strophe 当前没有使用该功能。

## 2. 许可证边界

`build.sh` 显式向 FFmpeg configure 传递：

```bash
--disable-gpl
--disable-version3
--disable-nonfree
--disable-avfilter
--disable-libzimg
--disable-libzvbi
```

最终组合为：

- FFmpeg 五个动态库：LGPL-2.1-or-later。
- dav1d：BSD-2-Clause。

动态 framework 便于满足 LGPL 对库替换/重新链接能力的要求。发布 App
时仍需附带相应许可证文本，并指向所发布二进制对应的 FFmpegBuild fork
源码版本。

## 3. 环境准备

需要 Xcode 16+、Meson、Ninja、pkg-config 和 NASM：

```bash
brew install meson ninja pkg-config nasm
```

zimg 和 libzvbi 已移除，因此不再需要 autoconf、automake、GNU libtool
或 gettext。

## 4. 从干净状态重新编译

```bash
cd /Users/maqa/codelearn/FFmpegBuild
./build.sh clean
./build.sh
```

`clean` 会删除 `build/` 以及 `Sources/` 下旧的 `.xcframework`，包括历史
遗留的 Libavfilter、Libzimg 和 Libzvbi。首次编译会拉取固定版本的
FFmpeg n8.1.2 和 dav1d 1.5.1。

输出目录：

```text
/Users/maqa/codelearn/FFmpegBuild/Sources
```

## 5. 产物验证

确认只剩六个 xcframework：

```bash
find Sources -maxdepth 1 -name '*.xcframework' -print
```

每个 xcframework 的 `Info.plist` 应只包含：

- `ios-arm64`
- `macos-arm64_x86_64`

检查 macOS 二进制架构：

```bash
lipo -archs Sources/Libavcodec.xcframework/macos-arm64_x86_64/Libavcodec.framework/Versions/A/Libavcodec
```

检查运行时依赖中不存在被移除的库：

```bash
otool -L Sources/Libavcodec.xcframework/macos-arm64_x86_64/Libavcodec.framework/Versions/A/Libavcodec
```

输出不应出现 `Libavfilter`、`Libzimg` 或 `Libzvbi`。`Libavcodec` 仍会依赖
`Libdav1d` 和 `Libavutil`，这是预期行为。

## 6. Xcode 接入与签名

在 Strophe target 的 “Frameworks, Libraries, and Embedded Content” 中只添加
上述六个 `.xcframework`，全部设置为 `Embed & Sign`。

在 Build Phases 的 “Embed Frameworks” 中确认：

- 六个 framework 都在列表内。
- `Code Sign On Copy` 已启用。
- 不再存在 Libavfilter、Libzimg 或 Libzvbi 引用。

源目录里的 framework 使用 ad-hoc 签名是正常的。Xcode 会在嵌入
`Strophe.app/Contents/Frameworks` 时用 App 的签名身份重签副本。不要直接
修改 `FFmpegBuild/Sources` 中原始 framework 的签名。

变更 framework 集合后，在 Xcode 执行 Product → Clean Build Folder，再
重新构建 App，避免 DerivedData 中的旧 framework 被 dyld 命中。
