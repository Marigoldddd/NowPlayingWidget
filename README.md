<div align="center">

<img src="docs/logo.png" alt="Now Playing Widget logo" width="96">

# Now Playing Widget

### 把正在播放的音乐，放回 macOS 桌面。

支持网易云音乐、QQ 音乐、Apple Music 与 Spotify。
显示歌曲、歌手、专辑、封面、播放状态，并支持播放控制与自定义未播放页。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-green.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-WidgetKit-orange.svg)](https://developer.apple.com/documentation/widgetkit)
[![NetEase Music](https://img.shields.io/badge/NetEase%20Music-Supported-red.svg)](https://music.163.com/)
[![QQ Music](https://img.shields.io/badge/QQ%20Music-Supported-31c27c.svg)](https://y.qq.com/)
[![Apple Music](https://img.shields.io/badge/Apple%20Music-Supported-fa243c.svg)](https://music.apple.com/)
[![Spotify](https://img.shields.io/badge/Spotify-Supported-1DB954.svg)](https://www.spotify.com/)

</div>

---

## ✨ 这是什么？

**Now Playing Widget** 是一个 macOS 桌面音乐小组件。

它不是播放器，也不会接管你的音乐应用。
它只是把系统当前正在播放的音乐信息，整理成一张更适合放在桌面上的卡片。

<div align="center">

| 🎵 正在播放       | 🎨 多套皮肤     | 🕹️ 播放控制            |
| ------------- | ------------ | ------------------- |
| 歌曲、歌手、专辑、播放状态 | 经典卡片 / 黑胶唱片 / 全屏海报 | 播放 / 暂停 / 上一首 / 下一首 |

| 🖼️ 高清封面     | 💤 未播放状态  | 🧩 小组件尺寸   |
| ------------- | --------- | ---------- |
| 低清封面自动联网补全大图 | 支持自定义显示图片 | 支持小号与中号小组件 |

</div>

---

## 🖼️ 效果预览

<table>
  <tr>
    <td align="center" width="50%">
      <img src="docs/image1_netease_music.png" alt="网易云音乐预览" width="420">
      <br>
      <sub>网易云音乐</sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/image2_applemusic.png" alt="Apple Music 预览" width="420">
      <br>
      <sub>Apple Music</sub>
    </td>
  </tr>
  <tr>
    <td align="center" width="50%">
      <img src="docs/image3_Transparent.png" alt="透明渲染模式" width="420">
      <br>
      <sub>透明渲染模式</sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/image4_idle.png" alt="未播放状态" width="420">
      <br>
      <sub>未播放状态</sub>
    </td>
  </tr>
</table>

---

## 🚀 快速开始

### 下载使用

从 GitHub Releases 下载 DMG，将 `NowPlayingWidget.app` 拖入
`Applications` 后运行即可。

Release 版本已经内置 Universal `arm64 + x86_64` 的
`nowplaying-cli 2.1.0`，不需要安装 Homebrew 或额外依赖。

### 使用 Xcode 运行

1. 克隆本仓库；
2. 用 Xcode 打开 `NowPlayingWidget.xcodeproj`；
3. 首次构建会从固定的上游源码构建 Universal `nowplaying-cli`；
4. 分别选择 `NowPlayingWidget` 和 `NowPlayingWidgetExtension`；
5. 在 **Signing & Capabilities** 中设置自己的 Team；
6. 建议把两个 Bundle Identifier 改成自己的反向域名；
7. 构建并运行 `NowPlayingWidget`；
8. 播放网易云音乐、QQ 音乐、Apple Music 或 Spotify；
9. 在桌面右键进入「编辑小组件」，添加正在播放小组件。

正常打开应用会显示主页面，可通过标签切换「概览」「外观」「帮助」。
「同步小组件」会依次读取播放信息、写入数据并请求桌面更新，同时显示每一步的结果。
桌面真正更新的时机由 macOS 决定。打开数据目录和自定义未播放图片也可在主页面操作。
关闭窗口后仍会继续同步，菜单栏保留以下入口：

```text
打开主页面 / 退出
```

### 构建 GitHub Release DMG

```sh
./Scripts/build-release-dmg.sh
```

输出文件位于：

```text
build/release/NowPlayingWidget-v<version>-macOS-universal.dmg
```

构建成功后会自动删除 DerivedData 和 DMG 暂存目录，只保留最终的
`.dmg` 发布文件。

生成的 DMG 使用 ad-hoc 签名，没有 Apple 公证。首次打开时可能需要在
Finder 中右键应用并选择「打开」。

---

## ⚙️ 配置

### 支持的播放器

```text
com.netease.163music
com.tencent.QQMusicMac
com.apple.Music
com.spotify.client
```

当前显示哪个播放器，取决于 macOS 系统当前暴露的正在播放信息。
QQ 音乐通过相同的系统媒体接口读取歌曲、歌手、封面和播放状态，
播放 / 暂停 / 上一首 / 下一首也发送给系统当前的媒体播放器。
如果 QQ 音乐未向系统提供正在播放信息，或不响应媒体命令，
小组件无法自行补全信息或强制控制；请先检查控制中心的「正在播放」。

---

### Widget 标识符

如果修改了 Widget Extension 的 Bundle Identifier，需要同步修改：

```swift
// Shared/NowPlayingShared.swift
static let widgetKind = "<your-widget-bundle-id>"
static let widgetBundleID = "<your-widget-bundle-id>"
```

---

### 数据目录

默认数据写入位置：

```text
~/Library/Containers/<widget-bundle-id>/Data/Library/Application Support/NowPlayingWidget/
```

里面主要有两个文件：

| 文件                | 作用                       |
| ----------------- | ------------------------ |
| `nowplaying.json` | 保存歌曲、歌手、专辑、播放状态、封面状态和背景色 |
| `cover.jpg`       | 保存当前歌曲封面                 |
| `appearance.json` | 保存当前选中的小组件皮肤样式             |

---

## 🧠 实现简述

项目由一个菜单栏助手和一个 WidgetKit 小组件组成。

菜单栏助手负责读取 macOS 正在播放信息，并把歌曲数据写入本地文件；小组件读取这些文件后，在桌面上渲染正在播放卡片。

为了降低本地构建和签名配置成本，项目没有使用 App Group，而是直接写入 Widget Extension 的容器目录。因此修改 Widget Bundle Identifier 后，需要同步修改共享配置。

---

## 🛠️ 常见问题

<details>
<summary>小组件一直显示等待状态</summary>

请先确认：

1. 菜单栏助手正在运行；
2. 网易云音乐、QQ 音乐、Apple Music 或 Spotify 正在播放；
3. 内置的 `nowplaying-cli` 可以正常读取信息；
4. 桌面上添加的是当前构建出来的小组件。

检查命令：

```sh
"/Applications/NowPlayingWidget.app/Contents/Resources/nowplaying-cli/bin/nowplaying-cli" get-raw
```

查看写入的数据：

```sh
cat "$HOME/Library/Containers/<widget-bundle-id>/Data/Library/Application Support/NowPlayingWidget/nowplaying.json"
```

</details>

<details>
<summary>数据已经更新，但小组件没有变化</summary>

可以尝试：

1. 在主页面「概览」中点击 `同步小组件`，查看读取、写入和刷新请求是否成功；
2. 如果刚覆盖安装了新版本，退出助手后执行以下命令，结束仍驻留的旧扩展，
   然后从「应用程序」重新打开 NowPlayingWidget：

```sh
killall NowPlayingWidgetExtension
```

3. 如果仍未更新，移除桌面上的旧小组件后重新添加。

覆盖安装不会立即结束已经运行的扩展进程。旧进程与新安装包的版本不一致时，
系统可能拒绝新的刷新结果；上面的操作不会删除自定义图片或共享数据。

</details>

<details>
<summary>如何查看封面是否正常写入？</summary>

```sh
sips -g pixelWidth -g pixelHeight "$HOME/Library/Containers/<widget-bundle-id>/Data/Library/Application Support/NowPlayingWidget/cover.jpg"
```

</details>

<details>
<summary>如何查看系统是否注册了小组件？</summary>

```sh
pluginkit -m -A -D -v -i <widget-bundle-id>
```

</details>

---

## ⚠️ 已知限制

* `nowplaying-cli` 依赖 macOS 的 MediaRemote 信息，系统更新后可能出现行为变化；
* 网易云音乐提供给系统的封面分辨率通常较低（约 `100x100`），应用会自动联网检索并补全高清封面，但冷门或无匹配曲目仍可能保留原缩略图；
* WidgetKit 有刷新预算和缓存策略，切歌后不一定立即刷新；
* 当前没有做播放器优先级选择，显示内容取决于 macOS 当前暴露的正在播放信息；
* 当前没有使用 App Group，修改 Widget Bundle Identifier 后需要同步修改配置。

---

## 🧩 第三方组件

Release 版本内置
[`nowplaying-cli 2.1.0`](https://github.com/kirtan-shah/nowplaying-cli)，
该组件采用 GPL-3.0-or-later 许可证。

应用资源目录中同时包含其完整 GPL 许可证和对应版本的源代码压缩包。
本项目自身仍采用 MIT License。

---

## 🗺️ 后续计划

* [x] 自定义未播放状态显示图片
* [x] 播放 / 暂停 / 上一首 / 下一首控制
* [x] 内置 Universal `nowplaying-cli`
* [x] 更多小组件样式（经典卡片 / 黑胶唱片 / 全屏海报）
* [ ] 支持更多播放器
* [ ] 提供预编译安装包
* [ ] 更完善的设置界面
* [ ] 更稳定的刷新策略

---

## 📄 许可证

本项目基于 MIT License 开源，详情见 [LICENSE](LICENSE)。
