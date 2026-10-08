# 应用内更新

WindowShade 使用 Sparkle 2.10.0 的标准更新流程和标准界面：检查更新清单，下载新版本，校验 EdDSA 签名，替换 App，重新打开。WindowShade 不在这一流程之外增加任何步骤。

2026-10-08 之前的版本另有更新看护进程、更新前备份、失败后恢复旧版本、启动记录和“移到‘应用程序’文件夹”一步，共约 3,800 行。这些代码已经删除，原因见 [design.md](design.md) 第 3.7 节。

## 代码

| 位置 | 内容 |
|---|---|
| `prototype/App/Updater.swift` | `UpdaterController`：创建 `SPUStandardUpdaterController`，提供菜单项和自动检查开关；`UpdateCopy`：界面文字 |
| `prototype/App/Preferences.swift` 中的 `makeUpdateSettingsRows()` | 设置窗口“权限与启动”页的“更新”一组 |
| `prototype/App/MenuBarController.swift` | 菜单栏菜单中按住 ⌥ 显示的“检查更新…” |
| `prototype/Info.plist` | `SU*` 设置键和公钥 |
| `prototype/Vendor/Sparkle.framework` | Sparkle 2.10.0，已删除 XPCServices |

测试程序不链接 Sparkle。`App/Updater.swift` 用 `#if canImport(Sparkle)` 隔开 Sparkle 的调用，测试程序中的 `UpdaterController` 不启动更新器。

## 启动条件

`UpdaterController.start()` 在 `applicationDidFinishLaunching` 末尾调用。Info.plist 中 `SUFeedURL` 和 `SUPublicEDKey` 都不为空时才创建更新器。

- 发布版：`build.sh --stage` 写入 `SUFeedURL`（`https://windowshade.aaronlau.me/appcast.xml`），更新器启动。
- 开发版：`build.sh` 和 `build.sh --check` 不写 `SUFeedURL`，更新器不启动；菜单中的“检查更新…”、设置中的开关和“检查更新”按钮都不可用。开发版因此不会被线上版本替换。

## Info.plist 设置

| 键 | 值 | 作用 |
|---|---|---|
| `SUFeedURL` | 只在发布版中写入 | 更新清单地址 |
| `SUPublicEDKey` | `D/MZytH+oxawqKQsskoXBdwbvoPentrqfaj7Tj2pnkw=` | 校验下载包和清单的签名 |
| `SURequireSignedFeed` | true | 清单本身也必须带签名 |
| `SUVerifyUpdateBeforeExtraction` | true | 解压前校验签名 |
| `SUEnableAutomaticChecks` | true | 默认自动检查；Sparkle 不再询问是否允许自动检查 |
| `SUScheduledCheckInterval` | 86400 | 每天检查一次 |
| `SUAutomaticallyUpdate`、`SUAllowsAutomaticUpdates` | false | 不在后台自动安装，由用户在 Sparkle 的窗口中决定 |
| `SUEnableSystemProfiling` | false | 检查时不发送系统信息 |

`build.sh` 每次构建都把这些键从源码树的 Info.plist 同步到 App 中（`SUFeedURL` 除外）。

## 用户看到的界面

- 菜单栏菜单：按住 ⌥ 时显示“检查更新…”。
- 设置窗口“权限与启动”页，“更新”一组：“自动检查更新”开关（说明：有新版本时提示，不自动安装），“当前版本 x.y.z”和“检查更新”按钮。
- 发现新版本、下载、安装、出错时的窗口都是 Sparkle 的标准窗口，使用 Sparkle 自带的简体中文。

## 检查时发出的网络请求

- 检查：向 windowshade.aaronlau.me 发一次 HTTPS GET。User-Agent 为 Sparkle 的默认值（App 名称、版本号和 Sparkle 版本号）。不发送系统信息，没有查询参数，没有安装编号。
- 下载：向 GitHub Releases 及其跳转的下载服务器发请求。
- 不发送窗口画面、窗口标题、使用记录或崩溃信息。
- 关闭“自动检查更新”后，只在用户点“检查更新”时联网。

## 签名要求

Sparkle 安装新版本前校验下载包的 EdDSA 签名（与 `SUPublicEDKey` 对应）和新版本的代码签名，校验不通过时拒绝安装并显示错误。按 Sparkle 文档的规定，EdDSA 密钥和代码签名证书不能在同一个版本中同时更换。

辅助功能和屏幕录制授权绑定 App 的代码签名要求（DR）。新版本的 DR 必须与上一版逐字相同，否则用户更新后需要重新授权。发布前按 `DEVELOPMENT.md` 的“发布关”核对 DR。

**更换证书的版本**（证书续期后名称改变，或改用 Developer ID）：清单中把这一条标为 `sparkle:informationalUpdate`，并设置 `belowVersion=<更换证书后的第一个 build>`。Sparkle 对这一条只显示下载链接，不自动安装。同一版本不能同时更换 EdDSA 密钥和证书。

## 发布

发布步骤见 `DEVELOPMENT.md` 的“发布流程”。清单 `site/public/appcast.xml` 保留最近三条，每条的格式：

```xml
<item>
  <title>1.0.17</title>
  <pubDate>Tue, 06 Oct 2026 10:00:00 +0800</pubDate>
  <sparkle:version>17</sparkle:version>
  <sparkle:shortVersionString>1.0.17</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>
  <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
  <sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>
  <description><![CDATA[一句话写这一版改了什么]]></description>
  <enclosure url="https://github.com/surfine/WindowShade/releases/download/v1.0.17/WindowShade-v1.0.17.zip"
             length="…" type="application/octet-stream" sparkle:edSignature="…"/>
</item>
```

先上传 zip，再发布清单。顺序相反时，用户会先看到新版本却无法下载。

## 验收

每次升级 Sparkle 或修改 `App/Updater.swift` 后，在发布机上执行：

1. 安装上一版发布包，授予两项权限。
2. 用 `--stage` 构建一个 build 号更大的版本，签名后放到本地 HTTP 服务器，清单指向它。
3. 在上一版中点“检查更新…”：出现 Sparkle 的新版本窗口；点安装后 App 重新打开，版本号为新版本，两项授权仍然有效。
4. 把清单中的签名改错一个字符，再检查更新：Sparkle 显示错误，不安装。
5. 开发版（`build.sh`）中，“检查更新…”和设置中的两个控件都不可用。这一项由 `tests/run-appkit-tests.sh` 自动检查。
