<div align="center">

<img src="assets/app-icon/windowshade-app-icon.png" alt="WindowShade" width="112">

# WindowShade

**收起窗口，留下位置。**<br>
双击标题栏，窗口收成一条卷帘条，停在原处；再双击，它原样回来。<br>
指针停在卷帘条上，不用展开就能看一眼。<br>
免费开源的 Mac 窗口小工具。

[![版本](https://img.shields.io/github/v/release/surfine/WindowShade?style=flat-square&color=303b49)](https://github.com/surfine/WindowShade/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-14%2B-303b49?style=flat-square)](#下载)
[![Apple Silicon](https://img.shields.io/badge/download-Apple%20Silicon-303b49?style=flat-square)](#下载)
[![许可](https://img.shields.io/badge/license-MIT-303b49?style=flat-square)](LICENSE)

[**下载 Mac 版**](https://github.com/surfine/WindowShade/releases/latest) · [**官网**](https://windowshade.aaronlau.me/) · [**介绍视频**](https://www.bilibili.com/video/BV1K7ag6WEdH/) · [**窗口往事**](https://windowshade.aaronlau.me/history/) · [English](README.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/readme-desk-dark.png">
  <img src="assets/readme-desk.png" alt="「参考资料」窗口收成一条卷帘条，停在原处，露出后面的文章草稿" width="720">
</picture>

<sub>官网首页的互动示意：「参考资料」收起后，后面的草稿露了出来。<a href="https://windowshade.aaronlau.me/">去官网亲手试一试 →</a></sub>

</div>

## 让开的办法有三种，只有一种不用回头找

窗口挡住了后面的东西，你多半会关掉它，或者最小化。两种都管用，只是回来的时候要费点工夫。

| | 窗口去了哪儿 | 回来的时候 |
| --- | --- | --- |
| **关掉** | 没了 | 重新打开，再翻回刚才那一页 |
| **最小化** | 进了 Dock | 先在 Dock 里认出它 |
| **收起** | 收成一条卷帘条，还在原处 | 双击卷帘条，它就回来 |

收起和最小化不一样：窗口不离开这张桌面。把卷帘条拖到别处，窗口就在新位置展开。

## 这个双击，比你的 Mac 还老

三十年前的 Mac 用户，大多会这一招。后来系统换了思路，把窗口送进 Dock，它就慢慢被人忘了。我们把这段往事写成了一篇可以动手的长文 **[窗口往事](https://windowshade.aaronlau.me/history/)**：七章，四个动手实验，14 条原始史料。

1. [先别关掉](https://windowshade.aaronlau.me/history/#space)：同一张桌面，三种安排，亲手比一比
2. [一个小工具](https://windowshade.aaronlau.me/history/#origin)：一份 1994 年的用户社群刊物
3. [点两下还是三下](https://windowshade.aaronlau.me/history/#preference)：改一次当年的控制面板
4. [有了按钮](https://windowshade.aaronlau.me/history/#button)：拖着收起的窗口换个地方
5. [去了 Dock](https://windowshade.aaronlau.me/history/#departure)：Dock、Exposé 与 Mission Control
6. [还有人在用](https://windowshade.aaronlau.me/history/#survival)：便笺至今还留着这一招
7. [回到今天](https://windowshade.aaronlau.me/history/#return)：旧动作，新的工作现场

读完还可以 [启动一台旧 Mac](https://windowshade.aaronlau.me/history/#lab)（System 7.5、Mac OS 8、Mac OS X 10.1，由 [Infinite Mac](https://infinitemac.org/) 运行），沿着当年的菜单自己找到这个设置。

今天的 WindowShade 是独立的 Swift / AppKit 实现，借用了老名字和老想法，代码从头写起。它不是 Apple 的产品，也没有用 Rob Johnston、Apple 或 Unsanity WindowShade X 的代码。

## 怎么用

收起，窗口留在原处；看一眼，不用展开就能看到它。要的那扇窗口一直在你知道的地方，不用去了再回来。

**收起窗口。** 双击标题栏，或按“收起或展开当前窗口”的快捷键，窗口收成一条卷帘条；双击卷帘条展开。收起后可以显示原标题栏、简化标题栏或缩略图，在“设置 → 卷帘 → 收起后显示”里选。卷帘条在最前面时按 Command-W、Command-M、Command-H、Command-Q、Command-N，作用在它背后的窗口和 App 上；按 Command-Q 会先展开窗口，要问“是否保存”时你看得见。

**看一眼。** 指针在卷帘条上停一下，卷帘条下面就挂出一张卡片，按原来的大小显示窗口里的内容；移开，它自己收回去。单击卡片才真正展开。卷帘条留在原处，卡片和它隔着一道缝，一看就知道这不是窗口本身。它不会切换当前的 App，也不会动任何窗口。有的窗口收起后拿不到实时画面，这时卡片上是收起那一刻的画面。

## 快捷键

从 1.0.16 起，新装的 WindowShade 不预设快捷键。在“设置 → 快捷键”里可以为“收起或展开当前窗口”和“整理卷帘条”录制快捷键，也可以打开“按编号展开”（Control-Command-1 至 9）。从 1.0.15 及更早版本升级的，保留下面这些快捷键。

| 升级后保留的快捷键 | 做什么 |
| --- | --- |
| `⌃⌘C` | 收起或展开当前窗口 |
| `⌃⌘1…9` | 按菜单里的顺序展开已收起的窗口 |
| `⌃⌘0` | 整理卷帘条，再按一次放回原位 |

“收起或展开当前窗口”和“整理卷帘条”可以在设置里改键或清除，“按编号展开”可以整组关掉；某个组合被别的应用占用时，会提示你一次。

## 下载

到 [Releases](https://github.com/surfine/WindowShade/releases/latest) 下载最新的 ZIP，解压，把 `WindowShade.app` 拖进“应用程序”打开，按提示在系统设置里允许辅助功能和屏幕录制。它只在菜单栏里显示图标，不占 Dock 位置。

- **1.0.15 下载包：** ZIP 4.06 MB，解压后的应用文件合计 7.98 MB（十进制；文件系统实际占用可能不同）。
- **要 macOS 14 以上、Apple Silicon。** 没有 Intel 版。
- **安装包还没公证。** 第一次打开如果被系统拦住，去“系统设置 → 隐私与安全性”点“仍要打开”。不用关掉系统的安全检查。
- 每次发布都附 SHA-256 校验文件。每个版本改了什么，见 [更新记录](https://github.com/surfine/WindowShade/releases)。

## 你的窗口，只留在你的 Mac 上

WindowShade 要用到系统设置里的两项：**辅助功能**，用来找到、移动、收起和展开窗口；**屏幕录制**，原标题栏、看一眼和缩略图要用窗口画面。“屏幕录制”只是系统给这一项起的名字，画面只在你的电脑上处理，不会传到别处。WindowShade 万一意外退出，下次打开时会把收起的窗口放回原处。

普通窗口都能收起。便笺用系统自己的收起方式；Adobe 这类自己画标题栏的应用会单独处理。全屏、分屏、台前调度和多显示器还有少数情况没覆盖，建议先在你常用的应用里试一次。碰到问题欢迎[反馈](https://github.com/surfine/WindowShade/issues)，写上 macOS 版本、应用名和操作步骤。

## 构建与参与

需要 macOS 14+、Xcode command line tools，以及 Apple Development 签名证书。

```sh
git clone https://github.com/surfine/WindowShade.git
cd WindowShade/prototype
./build.sh --check   # 编译检查，不签名
./build.sh           # 使用本机配置的身份构建、签名
open WindowShade.app
```

通过 `WINDOWSHADE_CODESIGN_IDENTITY` 或未跟踪的 `prototype/local-codesign.env` 配置签名。签名、隔离构建与发布步骤见 [DEVELOPMENT.md](DEVELOPMENT.md)；界面和官网文案按 [文案规则](docs/copy-guide.md) 写。

| 仓库入口 | 内容 |
| --- | --- |
| [`prototype/`](prototype/) | 原生应用：窗口策略、捕获、卷帘条与恢复 |
| [`tests/`](tests/) | 状态、恢复、快捷键与纸面组件检查 |
| [`site/`](site/) | 部署在 Cloudflare Pages 的中英文官网与窗口往事 |
| [`docs/performance.md`](docs/performance.md) | 实测结果，以及尝试过但没有奏效的办法 |
| [`docs/releases/`](docs/releases/) | 历次发布说明 |
| [`WindowShade.md`](WindowShade.md) | 最初的设计理由与研究笔记 |

修改窗口行为时，请写明应用和窗口类型、修改前后的表现，以及做过的检查。

## 致谢与许可

本项目代码采用 [MIT](LICENSE)。历史软件和名称属于各自作者。窗口往事感谢 [Infinite Mac](https://infinitemac.org/)、Marcin Wichary 的 [《偏好之形》](https://aresluna.org/frame-of-preference/)，以及提供时代外观实现参考的 [AI System 6](https://github.com/surfine/AI-System-6)。随站点分发的字体和参考资源许可保留在 [`site/public/fonts/`](site/public/fonts/)。
