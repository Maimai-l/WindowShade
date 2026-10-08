# WindowShade 开发指南

面向开发者的构建、签名、模块结构、调试与发布流程。用户向内容见 [README](README_CN.md)。

## 环境要求

- macOS 14 或更新版本
- Xcode Command Line Tools
- 用于签名的 Apple Development 证书（构建脚本强制要求，拒绝 ad-hoc 签名）

## 模块结构

```text
prototype/
├── main.swift                        # 入口（NSApplication + AppDelegate）
├── WindowShade.swift                 # 全局常量 + AppDelegate 骨架（启动、观察者、生命周期）
├── ScreenCaptureBridge.swift         # SCStream 捕获（看一眼的实时画面）
├── App/                              # AppDelegate 扩展（按功能拆分的控制器）
│   ├── MenuBarController.swift       # 状态栏图标、菜单重建与菜单代理回调
│   ├── Reconcile.swift               # 折叠会话监控（reconcile 定时核对/并行快照）
│   ├── EventTap.swift                # 全局快捷键、事件 tap、标题栏双击/三击
│   ├── EventTapCallback.swift        # CGEventTap 的 C 回调与标题栏带预过滤
│   ├── Permissions.swift             # 权限检测与隐私设置跳转
│   ├── StatusBarIcon.swift           # 状态栏模板图标
│   ├── SettingsWindow.swift          # 设置窗口（侧边栏与分页）
│   ├── Preferences.swift             # 设置各分页的内容与引导页
│   ├── GlobalShortcuts.swift         # 全局快捷键的设置与默认值；HotKey.swift 是一个组合的录制规则与显示名
│   ├── Glance.swift                  # 看一眼：指针停在卷帘条上时的画面卡片
│   ├── Thumbnail.swift               # 收成缩略图的外观
│   ├── SnapshotFlight.swift          # 展开时截图飞回原位
│   ├── OverlayPresentation.swift     # 覆盖层展示与 Space 不变量
│   ├── HoverPreview.swift            # 悬停预览（peek / 菜单悬停）
│   ├── OverlayFactory.swift          # 覆盖层窗口工厂（截图条/代理标题栏）
│   ├── ArrangeController.swift       # 卷帘条整理
│   ├── FoldTransaction.swift         # 折叠事务辅助（隐藏/恢复/验证/转发/通知）
│   ├── FoldCompletion.swift          # 等折叠终态的回调（标题栏三击）
│   ├── ShadeController.swift         # 折叠入口（shade/toggle/折叠计划/截图）
│   ├── FoldExit.swift                # 折叠出口（unshade/清理/交通灯/QuickLook）
│   └── Updater.swift                 # 应用内更新：Sparkle 标准控制器、菜单项（docs/update.md）
├── Private/
│   └── SkyLightBridge.swift          # SkyLight 私有 API 隔离层（全部有 fallback）
├── Domain/                           # 领域层：只依赖 Foundation，单元测试直接编译（tests/run-domain-tests.sh）
│   ├── AppProfiles.swift             # 应用程序配置表：按应用程序区分的处理全部在这里
│   └── FoldPlanner.swift             # 收起计划：收不收、卷帘条的样子、原窗口怎么移开
├── Platform/                         # 平台层：系统调用集中在这里，可在后台线程执行
│   ├── ScreenLayout.swift            # 屏幕几何快照（辅助功能坐标）
│   ├── WindowHider.swift             # 移开原窗口的顺序；WindowControl 协议
│   ├── FocusHandoff.swift            # 收起时把焦点交给哪个窗口；FocusControl 协议
│   └── WindowControlSystem.swift     # WindowControl、FocusControl 的真实实现（辅助功能、SkyLight）
├── Core/
│   ├── WindowState.swift             # 折叠操作状态机（非法转换拒绝）
│   └── ShadeModels.swift             # 折叠相关值类型（ShadeState、策略、外框画像）
├── Capture/
│   ├── WindowSnapshotCache.swift     # 折叠截图 500ms 短 TTL 缓存
│   ├── PreviewRenderer.swift         # 渲染与图像分析（chrome 扫描、圆角镜像、条制备）
│   └── ShareableContentCache.swift   # SCShareableContent 短 TTL 缓存
├── Overlay/
│   ├── ShadeStripPool.swift          # 简单卷帘条窗口池（OverlayWindow 复用）
│   └── ShadeStrip.swift              # 覆盖层视图（截图条/代理标题栏/预览窗）
├── Window/
│   ├── WindowRegistry.swift          # app 元数据（名称/bundleID）短 TTL 缓存
│   ├── AXWindow.swift                # AX 辅助（几何/ID 解析/chrome 探测/按钮交互）
│   ├── AXHelpers.swift               # 交通灯、QuickLook 重开、系统标题栏设置、唤回回调
│   ├── AppWindows.swift              # 应用窗口枚举（事务备忘/并发）与显示标题
│   ├── AppProfileLookup.swift        # 按进程取应用程序配置
│   ├── FoldWindowRead.swift          # 收起前在后台读窗口
│   ├── ChromeProfile.swift           # 窗口外框画像与缓存
│   ├── Coordinates.swift             # AX / Cocoa 坐标换算与屏幕归属
│   └── WindowListCache.swift         # WindowServer 窗口列表缓存与单窗口查询
├── Support/
│   └── Diagnostics.swift             # 日志、主线程活动标记、慢调用日志、卡顿哨兵
├── Recovery/
│   ├── Journal.swift                 # 恢复日志数据层（持久化/匹配/生命周期标记）
│   ├── RestoreVerifier.swift         # 展开后确认窗口真的回来了，没回来就留着恢复记录
│   └── Rescue.swift                  # 离屏窗口救援编排（后台扫描 + 主线程写回）
└── Vendor/
    └── Sparkle.framework             # Sparkle 2.10.0，已删 XPCServices，符号链接保留（ditto 放入）
```

`build.sh` 会自动收集上述目录里的 `.swift` 文件（排序稳定，排除 `WindowShade.app`、
`dist`、`.build`、`Vendor`），新增源文件无需手工维护编译列表。

## 构建

构建脚本原地更新 `prototype/WindowShade.app`（保留 bundle、Info.plist 与资源）。
全新克隆没有 bundle 时，脚本会用仓库里的 `Info.plist` 与
`assets/app-icon/WindowShade.icns` 自动 bootstrap 一个最小 bundle；已有 bundle
则继续原地替换 Mach-O，保留 TCC 授权身份。

```sh
cd prototype
./build.sh
open WindowShade.app
```

本地反复检查界面时，若 LLVM 优化耗时过长，可用 `./build.sh --local-parallel`。
它保留 `-O -whole-module-optimization`，增加四个后端线程。
默认构建和 `--stage` 发布构建保持原编译选项，性能验收须注明所用模式。

只想验证编译、不签名也不改动 app bundle：

```sh
./build.sh --check
```

### 签名

`build.sh` 的签名身份来自环境变量或本机未跟踪配置文件（不写入 Git）：

```sh
WINDOWSHADE_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./build.sh
```

也可以写在 `prototype/local-codesign.env` 里（该文件已在 `.gitignore` 中）：

```sh
WINDOWSHADE_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
```

构建脚本默认拒绝 ad-hoc 签名：macOS 的 TCC 授权（辅助功能 / 屏幕录制）绑定签名
身份，重建 bundle 或换 ad-hoc 签名会重置权限。

### 编译验证（不签名，仅验证）

```sh
cd prototype
./build.sh --check
```

`--check` 复用 `build.sh` 同一份自动收集的源文件清单，只做 swiftc 类型检查，
不签名、不修改 app bundle。README 与本文档不再需要第二套独立的 swiftc 文件清单。
`--check` 与发布构建一样链接 `Vendor/Sparkle.framework`；测试程序不链接 Sparkle，`App/Updater.swift`
靠 `#if canImport(Sparkle)` 编成不启动更新器的版本。

日常 `./build.sh` 出来的开发版不写 `SUFeedURL`，更新器不启动，不会被线上版本换掉；只有 `--stage` 写。
签名从里往外逐个签（Sparkle 的 Autoupdate、Updater.app、框架，最后主程序），全部同一个身份，不用 `--deep`。

## 测试

每个 `tests/run-*.sh` 编一个小的测试程序并运行，只用到它列出的源文件；CI（`.github/workflows/ci.yml`）在 macOS 上逐个跑一遍，结果表在 job summary 里。

| 范围 | 命令 |
|---|---|
| 设置窗口（含“更新”一组在开发版不可用）、看一眼的生命周期与卷帘条的红绿灯（离屏 AppKit） | `bash tests/run-appkit-tests.sh all` |
| 看一眼的指针意图 | `bash tests/run-glance-tests.sh` |
| 应用程序配置表、收起计划 | `bash tests/run-domain-tests.sh` |
| 移开原窗口的顺序、转移焦点（模拟窗口） | `bash tests/run-window-hider-tests.sh`、`bash tests/run-focus-handoff-tests.sh` |
| 收起时把窗口停到屏幕角上 | `bash tests/run-corner-parking-tests.sh` |
| 缩略图布局与半透明 | `bash tests/run-thumbnail-tests.sh` |
| 收起与展开的声音 | `bash tests/run-shade-sound-tests.sh` |
| 应用菜单与菜单栏菜单 | `bash tests/run-standard-menu-tests.sh` |
| 窗口列表缓存、AX 读取名额 | `bash tests/run-window-list-cache-tests.sh`、`bash tests/run-ax-read-gate-tests.sh` |
| 纸面组件与系统外观 | `bash tests/run-paper-tests.sh` |
| 快捷键默认值与录制规则 | `bash tests/run-quiet-defaults-tests.sh` |
| 日志写入、卡顿采样 | `bash tests/run-secure-log-tests.sh`、`bash tests/run-stall-sampler-tests.sh` |

## 调试

- 日志写在 `~/Library/Logs/WindowShade/windowshade.log`：目录 0700、文件 0600，拒绝符号链接，5MB 轮转（旧文件为 `.1`），不写窗口标题。开发时可用 `WINDOWSHADE_LOG_PATH` 指到一个已存在、只有自己可写的目录；共享的 `/tmp` 不行。
- 主线程卡顿：日志里搜 `main-thread stall`，会附带卡顿窗口内累计占用最久的标记及占比；`未标记` / `占 0%` 说明阻塞落在所有标记之外（多半在异步回调里）。
- 慢操作：日志里搜 `slow:` 前缀。
- 状态机：日志里搜 `state:` 前缀；非法状态转换会记录 `state: illegal transition`。
- 私有 API 降级：SkyLight 不可用时相关调用返回失败，日志可见 `private SLS ... unavailable`。
- 系统外观（材质 / 对比度边线 / 薄纱 / 动画 / 可访问性文案）集中在 `prototype/Overlay/SystemAppearance.swift`：新增自定义表面时用 `SystemMaterialView`，在 `applySystemAppearance(capabilities:)` 里读 `SystemAppearancePolicy`，不要在调用点各自判断 `accessibilityDisplayShould*`。
- 代理应用的主菜单：WindowShade 是 `LSUIElement`，不显示菜单栏，但文本编辑快捷键与 ⌘W 依赖主菜单的 key equivalent，菜单由 `prototype/App/StandardMenu.swift` 生成。
- 激活应用统一用 `NSApp.activate()`（macOS 14+ 协作式），不要再用 `activate(ignoringOtherApps:)`。

用户向说明见 [docs/glance.md](docs/glance.md)。
动手优化性能之前先读 [docs/performance.md](docs/performance.md)：那里记了实测的调用成本、已走通的手法和已经证伪的方向。

## 发布前测试清单

在以下应用上验证折叠 / 展开、双击标题栏、看一眼、菜单管理、`⌃⌘1...9`、`⌃⌘0`：

- Finder
- Safari
- Chrome
- Telegram
- WeChat
- Adobe Photoshop
- Premiere
- After Effects
- System Settings

异常场景：

- 杀掉 WindowShade 进程后，journal 能把停车窗口救回（启动后自动救援）。
- 无录屏权限时原貌卷帘降级为代理标题栏，不崩溃。
- 快速连续双击 / 快捷键不破坏窗口状态（状态机拒绝非法转换）。

## 发布流程

带更新器以后，每个公开的包都会被已装的 App 当成新版本，所以规则比以前严：

1. **每个公开的包都升 `CFBundleVersion`**（`prototype/Info.plist`，同时升 `CFBundleShortVersionString`）。不再移动已发布的 tag，不再 `--clobber`；
   换包就升一个小版本。以前的“同一版本重新发布”一节作废。
2. `./build.sh --stage` 隔离构建并签名，产物为 `.build/stage/WindowShade.app`，不会停止或覆盖日常运行的应用。
   它会写入 `SUFeedURL`，检查链接了 Sparkle、嵌套代码同一个 Team、`SUPublicEDKey` 没变、`WindowShade.swift` 启动了更新器。
   然后运行相关回归检查。
3. 打包（`ditto` 保留框架里的符号链接）：

   ```sh
   cd prototype
   VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
   mkdir -p dist
   ditto -c -k --sequesterRsrc --keepParent ../.build/stage/WindowShade.app "dist/WindowShade-v${VERSION}.zip"
   (cd dist && shasum -a 256 "WindowShade-v${VERSION}.zip" > "WindowShade-v${VERSION}.zip.sha256")
   ```

4. **发布关**：检查要发出去的这个 zip，不是构建目录；有一项不过就停下。`scripts/release-gate.sh` 还没写，先按下面手动做：
   1. `gh release download` 取上一版的发布包，`codesign -d -r- <App>` 读出它的 DR。
   2. 新 zip 解到临时目录，里面只有一个 `WindowShade.app`，`codesign --verify --deep --strict` 通过。
   3. 新版的 DR 和上一版逐字相同，`codesign --verify -R="=<上一版 DR>"` 通过。不同就只能走“换证书的一版”（docs/update.md）。
   4. `CFBundleVersion` 大于上一版。
   5. `LSMinimumSystemVersion` 和清单的 `minimumSystemVersion` 按版本号比相等（`14.0` 等于 `14.0.0`）。
   6. `lipo -archs` 和清单的 `hardwareRequirements` 一致。
   7. 链接了 Sparkle，`SUPublicEDKey`、`SUFeedURL` 没变。
   8. 打开新版，菜单里按住 ⌥ 出现的“检查更新…”能用，检查结果为“已是最新版本”。
5. 提交并推送实际构建的源文件、版本与发布说明，打新标签，上传 zip 和 `.sha256`，再下载回来核对 SHA-256：

   ```sh
   # 仍在 prototype/ 目录下执行
   VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
   git tag "v${VERSION}" && git push origin "v${VERSION}"
   gh release create "v${VERSION}" \
     "dist/WindowShade-v${VERSION}.zip" "dist/WindowShade-v${VERSION}.zip.sha256" \
     --title "WindowShade v${VERSION}" \
     --notes-file "../docs/releases/v${VERSION}.md"
   curl -L -o /tmp/ws-check.zip "https://github.com/surfine/WindowShade/releases/download/v${VERSION}/WindowShade-v${VERSION}.zip"
   shasum -a 256 /tmp/ws-check.zip; cat "dist/WindowShade-v${VERSION}.zip.sha256"
   ```

6. **清单**（`scripts/make-appcast.sh` 还没写，先手动）：`sign_update dist/WindowShade-v${VERSION}.zip` 得到 `sparkle:edSignature` 和
   `length`，在 `site/public/appcast.xml` 加一条（保留最近三条，写法见 docs/update.md“发布流程”里的条目样子），改动说明取
   `docs/releases/v<版本>.md` 开头最多三行；再给整个清单签名，`npm run deploy`，最后 `curl` 一次线上的清单。
   先上传包、后发清单，反过来他会先看到新版本却下载不到。
7. **分批推送**：条目带 `sparkle:phasedRolloutInterval` 86400。**撤回一版**：从清单删掉那一条再部署。

`prototype/dist/` 已在 `.gitignore` 中，发布产物不会污染工作区。默认构建架构为本机架构；发布说明须标明实际架构。Apple Development 签名不等于公证，不宣称已经 notarized。

### 更新签名的密钥

- EdDSA 私钥只在 Aaron 的登录钥匙串里（账户名 `windowshade`），另有一份加密的离线备份，永不进仓库、不导出到别处。
  `sign_update` 从钥匙串读它；Sparkle 的命令行工具在 Sparkle 2.10.0 发布包的 `bin/` 里（`sign_update`、`generate_appcast`）。
- 公钥 `D/MZytH+oxawqKQsskoXBdwbvoPentrqfaj7Tj2pnkw=` 写在 `prototype/Info.plist` 的 `SUPublicEDKey`，`build.sh` 的 `EXPECTED_ED_KEY`
  也记了一份，`--stage` 时比对。
- 私钥丢了没有兜底：所有人要手动装一次带新公钥的版本。换密钥要单独发一版（用旧私钥签、Info.plist 换新公钥），这一版不能同时换证书。

### 证书续期（开发证书 2027-06-14 到期，2027 年 5 月前做）

1. 同一个账号下申请新的 Apple Development 证书。钥匙串里两张同名证书会让 `codesign` 报身份不唯一，
   `WINDOWSHADE_CODESIGN_IDENTITY` 改用新证书的 SHA-1。
2. `--stage` 后跑发布关。DR 逐字相同就照常发；不同就按 docs/update.md 的“换证书的一版”发（清单 `informationalUpdate` 配 `belowVersion`，
   发布说明写明要手动安装、重新授权）。
3. 确认新证书发的第一版在测试账户上授权还在，再删旧证书。

### 升级 Sparkle

1. 下载新版本的 `Sparkle-<版本>.tar.xz`，核对官方发布页的 SHA-256。
2. `rm -rf prototype/Vendor/Sparkle.framework && ditto <解包目录>/Sparkle.framework prototype/Vendor/Sparkle.framework`（`ditto` 保留符号链接），
   再删掉 `prototype/Vendor/Sparkle.framework/Versions/B/XPCServices` 和顶层的 `XPCServices` 链接（没开沙盒用不到）。
   `build.sh` 的注释和本节的版本号一起改。
3. 读发布说明，留意标准界面、安装器和 Info.plist 键有没有变。
4. 跑 `tests/run-appkit-tests.sh all`，再在发布机上把 docs/update.md“验收”一节走一遍。
