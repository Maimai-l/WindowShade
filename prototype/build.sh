#!/bin/bash
# 编译 WindowShade 并原地替换现有 app bundle 里的 Mach-O，用稳定开发者证书签名。
#
# 用法：
#   ./build.sh            构建 + 签名（需要签名身份，见下）
#   ./build.sh --check    隔离优化编译与链接验证，不签名、不修改 app bundle
#   ./build.sh --stage    隔离构建到 .build/stage/（发布包从这里打），写入更新清单地址 SUFeedURL
#   ./build.sh --local-parallel  本地全模块优化，使用四个后端线程；发布仍用 --stage
#
# 应用内更新（docs/update.md）：主程序链接 prototype/Vendor/Sparkle.framework（2.10.0，已删 XPCServices），
# 用 Sparkle 的标准流程和界面。嵌套代码从里往外逐个签，全部用同一个身份，不用 --deep。
# --check 与应用一样编译并链接 Sparkle；
# 缺少 Sparkle 时检查直接失败，不会把“跳过了 Sparkle 接口的编译”当成完整链接通过。
# 日常 ./build.sh 出来的开发版不写 SUFeedURL，更新器不启动，不会被线上版本换掉。
#
# 签名身份（二选一）：
#   1. 环境变量：WINDOWSHADE_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
#   2. 本机未跟踪配置文件 prototype/local-codesign.env（不入 Git）：
#        WINDOWSHADE_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
#   默认拒绝 ad-hoc 签名：项目希望保持 TCC 权限身份，换签名身份会重置
#   辅助功能 / 屏幕录制授权。
set -euo pipefail
cd "$(dirname "$0")"

stage_only=0
if [ "${1:-}" = "--stage" ]; then stage_only=1; fi
OPTIMIZATION_FLAGS=(-O -whole-module-optimization)
# 工具链版本不等于语言模式。四次 Swift 编译都用同一组语言参数。
SWIFT_LANGUAGE_FLAGS=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors)
if [ "${1:-}" = "--local-parallel" ]; then OPTIMIZATION_FLAGS+=(-num-threads 4); fi
APP="WindowShade.app"
if [ "$stage_only" = "1" ]; then
  APP="$(cd .. && pwd)/.build/stage/WindowShade.app"
fi
BIN="$APP/Contents/MacOS/WindowShade"
TMP_BIN="windowshade"
if [ "$stage_only" = "1" ]; then TMP_BIN="$(cd .. && pwd)/.build/stage/windowshade"; fi
MODULE_CACHE="$(cd .. && pwd)/.build/module-cache"
# 更新清单地址与 EdDSA 公钥：只由 --stage 写进发布包；公钥必须和仓库 Info.plist 里的一致。
FEED_URL="https://windowshade.aaronlau.me/appcast.xml"
EXPECTED_ED_KEY="D/MZytH+oxawqKQsskoXBdwbvoPentrqfaj7Tj2pnkw="
SPARKLE_FRAMEWORK="$(pwd)/Vendor/Sparkle.framework"
# macOS 自带的 bash 3.2 在 `set -u` 下展开空数组会报错退出，有 EXIT trap 时退出码还是 0，
# 于是缺少 Vendor/Sparkle.framework 时 --check 什么都没编也返回成功。可能为空的数组（SPARKLE_FLAGS）用 + 展开形式。
SPARKLE_FLAGS=()
if [ -d "$SPARKLE_FRAMEWORK" ]; then SPARKLE_FLAGS=(-F "$(pwd)/Vendor"); fi

FRAMEWORKS=(
  -framework Cocoa
  -framework SwiftUI
  -framework Carbon
  -framework ApplicationServices
  -framework ScreenCaptureKit
  -framework QuartzCore
  -framework CoreText
  -framework AVFoundation
  -framework Vision
  -framework ServiceManagement
  -framework IOKit
  -framework CoreImage
  -framework VideoToolbox
  -framework Security
  -framework CoreAudio
  -framework MapKit
  -framework LocalAuthentication
  -framework LocalAuthenticationEmbeddedUI
  -framework GameController
)

# 自动收集源文件：只扫 prototype/ 与它的模块子目录，顺序稳定（按路径排序）。
# 用 -prune 排除 app bundle、dist、.build，避免把构建产物或其它仓库内容扫进来。
# Vendor/ 是第三方框架，不进源文件清单。TapHelper/ 是另一个程序（鼠标钩子进程），单独编译。
# macOS 自带 Bash 3.2 可运行（只用 find + sort + grep）。
collect_sources() {
  find . \
    -path "./WindowShade.app" -prune -o \
    -path ./dist -prune -o \
    -path ./.build -prune -o \
    -path ./Vendor -prune -o \
    -path ./TapHelper -prune -o \
    -name '*.swift' -print \
    | sed 's|^\./||' \
    | sort
}

check_only=0
if [ "${1:-}" = "--check" ]; then
  check_only=1
fi

# --check 不执行本机签名配置；普通构建仍按环境变量、配置文件的顺序读取。
IDENTITY="${WINDOWSHADE_CODESIGN_IDENTITY:-}"
if [ "$check_only" != "1" ] && [ -z "$IDENTITY" ] && [ -f local-codesign.env ]; then
  # shellcheck disable=SC1091
  source local-codesign.env
  IDENTITY="${WINDOWSHADE_CODESIGN_IDENTITY:-}"
fi

SOURCES="main.swift $(collect_sources | grep -v '^main.swift$')"
echo "==> 源文件：$(collect_sources | wc -l | tr -d ' ') 个 Swift 文件"

# 编译条件探测：当前 SDK 是否带公开的 AppKit Liquid Glass API。
# 用真实头文件存在性判断，而不是猜 Swift 版本；旧 SDK 构建时玻璃分支不参与编译。
GLASS_DEFINE=""
if [ -f "$(xcrun --show-sdk-path --sdk macosx)/System/Library/Frameworks/AppKit.framework/Headers/NSGlassEffectView.h" ]; then
  GLASS_DEFINE="-DWINDOWSHADE_SDK_HAS_GLASS"
fi
ARCH="${WINDOWSHADE_ARCH:-$(uname -m)}"
# 先复制一份源码快照再编译：长时间的优化编译期间改动文件，也不会影响签名包里的程序。
mkdir -p "$(cd .. && pwd)/.build"
WORK="$(mktemp -d "$(cd .. && pwd)/.build/build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
COMPILE_SOURCES=()
for source in $SOURCES; do
  mkdir -p "$WORK/$(dirname "$source")"
  cp "$source" "$WORK/$source"
  COMPILE_SOURCES+=("$WORK/$source")
done
# 鼠标钩子进程（docs/design.md 第 5.9 节）：只有 TapHelper/main.swift 和两边共用的 Core/TapProtocol.swift，
# 只链接 Foundation 和 CoreGraphics。语言参数和主程序相同。
HELPER_NAME="WindowShadeTapHelper"
compile_tap_helper() {
  mkdir -p "$WORK/TapHelper" "$WORK/helper-tmp"
  cp TapHelper/main.swift "$WORK/TapHelper/main.swift"
  env TMPDIR="$WORK/helper-tmp" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
    swiftc "${SWIFT_LANGUAGE_FLAGS[@]}" -module-cache-path "$MODULE_CACHE" -target "$ARCH-apple-macosx14.0" \
      -O -whole-module-optimization -o "$1" \
      "$WORK/TapHelper/main.swift" "$WORK/Core/TapProtocol.swift" -framework CoreGraphics
}
if [ "$check_only" = "1" ]; then
  # 和发布构建用同一套编译参数（-O -whole-module-optimization），只把产物写到临时目录、不签名、
  # 不碰 app bundle。只做 -typecheck 看不到整模块优化下才报的隔离、所有权问题。
  echo "==> 编译验证（--check，和发布构建同样的优化参数；不签名、不修改 app bundle）"
  mkdir -p "$MODULE_CACHE"
  env CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
    swiftc "${SWIFT_LANGUAGE_FLAGS[@]}" -module-cache-path "$MODULE_CACHE" -target "$ARCH-apple-macosx14.0" -O -whole-module-optimization ${GLASS_DEFINE} -o "$WORK/windowshade-check" \
      "${COMPILE_SOURCES[@]}" "${FRAMEWORKS[@]}" \
      "${SPARKLE_FLAGS[@]+"${SPARKLE_FLAGS[@]}"}" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks
  compile_tap_helper "$WORK/$HELPER_NAME-check"
  echo "==> 编译验证通过"
  # CI 的演示录屏要用这次编出来的程序：设了 WINDOWSHADE_CHECK_OUTPUT 就把它留下来。
  if [ -n "${WINDOWSHADE_CHECK_OUTPUT:-}" ]; then
    mkdir -p "$WINDOWSHADE_CHECK_OUTPUT"
    cp "$WORK/windowshade-check" "$WINDOWSHADE_CHECK_OUTPUT/WindowShade"
    cp "$WORK/$HELPER_NAME-check" "$WINDOWSHADE_CHECK_OUTPUT/$HELPER_NAME"
  fi
  exit 0
fi

if [ -z "$IDENTITY" ]; then
  echo "ERROR: 未提供签名身份。请设置 WINDOWSHADE_CODESIGN_IDENTITY，或创建" >&2
  echo "       prototype/local-codesign.env（该文件不提交进 Git）。拒绝 ad-hoc" >&2
  echo "       签名，避免重置 TCC 授权。" >&2
  exit 1
fi

if ! security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  echo "ERROR: 未找到签名身份 ${IDENTITY}；拒绝 ad-hoc 签名，避免重置 TCC 授权。" >&2
  exit 1
fi

if [ ! -f "$SPARKLE_FRAMEWORK/Versions/B/Sparkle" ]; then
  echo "ERROR: 缺少 prototype/Vendor/Sparkle.framework（Sparkle 2.10.0，升级流程见 DEVELOPMENT.md）。" >&2
  exit 1
fi

# 没有现成的 app bundle 时，用仓库里的 Info.plist 和应用图标搭一个最小的 bundle。
# 新克隆的仓库没有旧的 TCC 授权需要保护，所以不必先下载一份编译好的程序；
# 已有 bundle 时，仍原地替换 Mach-O，保留 TCC 身份。
if [ ! -d "$APP/Contents/MacOS" ]; then
  echo "==> 未找到现有 ${APP}，从源码仓库资源 bootstrap 最小 bundle"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp Info.plist "$APP/Contents/Info.plist"
  if [ -f ../assets/app-icon/WindowShade.icns ]; then
    cp ../assets/app-icon/WindowShade.icns "$APP/Contents/Resources/WindowShade.icns"
  else
    echo "WARNING: assets/app-icon/WindowShade.icns 缺失，bundle 将没有 app icon" >&2
  fi
fi

echo "==> 编译"
mkdir -p "$MODULE_CACHE"
mkdir -p "$WORK/compiler-tmp"
env TMPDIR="$WORK/compiler-tmp" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  swiftc "${SWIFT_LANGUAGE_FLAGS[@]}" -module-cache-path "$MODULE_CACHE" -target "$ARCH-apple-macosx14.0" "${OPTIMIZATION_FLAGS[@]}" ${GLASS_DEFINE} -o "$TMP_BIN" \
    "${COMPILE_SOURCES[@]}" "${FRAMEWORKS[@]}" \
    "${SPARKLE_FLAGS[@]+"${SPARKLE_FLAGS[@]}"}" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks
compile_tap_helper "$WORK/$HELPER_NAME"

if [ "$stage_only" != "1" ]; then
  echo "==> 停止这个 bundle 的 WindowShade（编译通过后才替换）"
  for task_pid in $(pgrep -x WindowShade 2>/dev/null || true); do
    task_executable=$(ps -p "$task_pid" -o comm= 2>/dev/null || true)
    if [ "$task_executable" = "$(pwd)/$BIN" ]; then kill -TERM "$task_pid" 2>/dev/null || true; fi
  done
fi
echo "==> 替换 Mach-O（保留 bundle、Info.plist、Resources）"
cp "$TMP_BIN" "$BIN"
cp "$WORK/$HELPER_NAME" "$APP/Contents/MacOS/$HELPER_NAME"
rm -f "$APP/Contents/Resources/Duo.metallib"
rm -f "$APP/Contents/Resources/LockOverlay-LICENSE.txt"
rm -rf "$APP/Contents/Resources/ThirdParty"
# 发布包一直在 Contents/Frameworks 里带着 Swift 并发运行时。隔离的发布构建也保留它；
# 否则发布包和已验证过的 app bundle 不一致，在没有对应工具链的系统上，可能在程序代码运行之前就失败。
SOURCE_FRAMEWORKS="$(pwd)/WindowShade.app/Contents/Frameworks"
if [ "$stage_only" = "1" ] && [ -d "$SOURCE_FRAMEWORKS" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$SOURCE_FRAMEWORKS/." "$APP/Contents/Frameworks/"
fi

# Sparkle：每次从 Vendor/ 重新放一份（ditto 保留符号链接），再按发布需要裁掉用不到的部分。
# 没开沙盒不需要 XPCServices；头文件和模块只给编译用；只留发布架构和 Base、zh_CN 两份本地化。
EMBED_FW="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$EMBED_FW"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$EMBED_FW"
SPARKLE_KB_BEFORE=$(du -sk "$EMBED_FW" | cut -f1)
for part in XPCServices Headers PrivateHeaders Modules; do
  rm -rf "${EMBED_FW:?}/$part" "${EMBED_FW:?}/Versions/B/$part"
done
for slice in "$EMBED_FW/Versions/B/Sparkle" "$EMBED_FW/Versions/B/Autoupdate" \
  "$EMBED_FW/Versions/B/Updater.app/Contents/MacOS/Updater"; do
  if [ "$(lipo -archs "$slice" | wc -w | tr -d ' ')" -gt 1 ]; then
    lipo -thin "$ARCH" "$slice" -output "$slice.thin"
    mv "$slice.thin" "$slice"
  fi
done
for lproj in "$EMBED_FW/Versions/B/Resources/"*.lproj; do
  case "$(basename "$lproj")" in
    Base.lproj|en.lproj|zh_CN.lproj) ;;
    *) rm -rf "$lproj" ;;
  esac
done
echo "==> Sparkle.framework：${SPARKLE_KB_BEFORE} KB → $(du -sk "$EMBED_FW" | cut -f1) KB（写进发布说明草稿）"

# 版本号以源码树里的 Info.plist 为准；只同步这两项，保留现有 bundle 的身份和本地资源。
for version_key in CFBundleShortVersionString CFBundleVersion; do
  release_value=$(/usr/libexec/PlistBuddy -c "Print $version_key" Info.plist)
  /usr/libexec/PlistBuddy -c "Set :$version_key $release_value" "$APP/Contents/Info.plist"
done
# 删掉旧版本留下的 Apple 事件、相机用途说明（源码树的 Info.plist 里已经没有这两项）。
plutil -remove NSAppleEventsUsageDescription "$APP/Contents/Info.plist" 2>/dev/null || true
plutil -remove NSCameraUsageDescription "$APP/Contents/Info.plist" 2>/dev/null || true
# 更新器的设置同样以源码树为准（SUFeedURL 除外：只有 --stage 写，开发版不写就不启动更新器）。
for su_key in SUPublicEDKey SUVerifyUpdateBeforeExtraction SURequireSignedFeed SUEnableAutomaticChecks \
  SUScheduledCheckInterval SUAllowsAutomaticUpdates SUAutomaticallyUpdate SUEnableSystemProfiling; do
  su_value=$(plutil -extract "$su_key" xml1 -o - Info.plist)
  plutil -replace "$su_key" -xml "$su_value" "$APP/Contents/Info.plist"
done
if [ "$stage_only" = "1" ]; then
  plutil -replace SUFeedURL -string "$FEED_URL" "$APP/Contents/Info.plist"
else
  plutil -remove SUFeedURL "$APP/Contents/Info.plist" 2>/dev/null || true
fi

echo "==> 用 Apple Development 证书签名（TCC 授权可跨重编保留）"
# 从里往外逐个签，全部同一个身份，不用 --deep：Sparkle 的安装器和 Updater.app 都要和 App 同一个 Team，
# 否则安装器和 App 之间的连接校验不过，新版替换自己也会被“App 管理”拦下。
# 主程序照旧：不加新标志（不加 hardened runtime），标识符不变，DR 不变。
codesign --force -s "$IDENTITY" -o runtime "$EMBED_FW/Versions/B/Autoupdate"
codesign --force -s "$IDENTITY" -o runtime "$EMBED_FW/Versions/B/Updater.app"
codesign --force -s "$IDENTITY" -o runtime "$EMBED_FW"
# 旧版本在这里放过 WindowShadeUpdateGuard.app；原地替换的开发版里可能还留着，删掉。
rm -rf "$APP/Contents/Helpers/WindowShadeUpdateGuard.app"
rmdir "$APP/Contents/Helpers" 2>/dev/null || true
# 鼠标钩子进程和主程序一样不加 hardened runtime：它由 WindowShade 启动，辅助功能授权算在 WindowShade 身上。
codesign --force -s "$IDENTITY" "$APP/Contents/MacOS/$HELPER_NAME"
codesign --force -s "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

if [ "$stage_only" = "1" ]; then
  echo "==> 发布前检查：Sparkle 已链接、嵌套代码同一个 Team、更新公钥没变"
  if ! otool -L "$BIN" | grep -q "@rpath/Sparkle.framework"; then
    echo "ERROR: 主程序没有链接 Sparkle。" >&2
    exit 1
  fi
  team_of() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
  MAIN_TEAM="$(team_of "$APP")"
  for nested in "$EMBED_FW/Versions/B/Autoupdate" "$EMBED_FW/Versions/B/Updater.app" "$EMBED_FW" \
    "$APP/Contents/MacOS/$HELPER_NAME"; do
    if [ -z "$MAIN_TEAM" ] || [ "$(team_of "$nested")" != "$MAIN_TEAM" ]; then
      echo "ERROR: ${nested#"$APP"/} 的 Team 和主程序不同（${MAIN_TEAM:-无}）。" >&2
      exit 1
    fi
  done
  if [ "$(plutil -extract SUPublicEDKey raw -o - "$APP/Contents/Info.plist")" != "$EXPECTED_ED_KEY" ]; then
    echo "ERROR: SUPublicEDKey 和记下的公钥不同；换密钥要单独发一版，见 docs/update.md。" >&2
    exit 1
  fi
  if ! grep -qF "UpdaterController.shared.start()" WindowShade.swift; then
    echo "ERROR: WindowShade.swift 没有启动更新器（UpdaterController.shared.start()）。" >&2
    exit 1
  fi
fi
touch "$APP"

echo "==> 完成：$APP"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'
