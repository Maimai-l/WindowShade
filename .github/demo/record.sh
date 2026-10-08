#!/bin/bash
# 在 CI 的 macOS 机器上编出 WindowShade、授权、录一段收起 / 看一眼 / 展开的视频。
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT="$PWD/.build/demo"
mkdir -p "$OUT"
csrutil status || true
sw_vers
system_profiler SPDisplaysDataType | grep -E "Resolution|Display Type" || true

echo "==> build"
WINDOWSHADE_CHECK_OUTPUT="$OUT/bin" prototype/build.sh --check || exit 1

APP="$OUT/WindowShade.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp prototype/Info.plist "$APP/Contents/Info.plist"
cp "$OUT/bin/WindowShade" "$APP/Contents/MacOS/WindowShade"
cp "$OUT/bin/Duo.metallib" "$APP/Contents/Resources/Duo.metallib"
cp assets/app-icon/WindowShade.icns "$APP/Contents/Resources/" 2>/dev/null || true
ditto prototype/Vendor/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --deep -s - "$APP"

DRIVER="$OUT/DemoDriver.app"
rm -rf "$DRIVER"
mkdir -p "$DRIVER/Contents/MacOS"
swiftc -swift-version 5 -parse-as-library -O .github/demo/DemoDriver.swift \
  -o "$DRIVER/Contents/MacOS/DemoDriver" -framework AppKit -framework ScreenCaptureKit || exit 1
cat > "$DRIVER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.windowshade.demo-driver</string>
<key>CFBundleExecutable</key><string>DemoDriver</string>
<key>CFBundleName</key><string>DemoDriver</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force -s - "$DRIVER"

echo "==> grant permissions"
sudo python3 .github/demo/grant-tcc.py \
  "com.windowshade.prototype=$APP" "com.windowshade.demo-driver=$DRIVER"
sudo killall tccd 2>/dev/null || true
# macOS 15 起，屏幕录制另有一层“要不要绕过系统窗口选择器”的确认框；预先批准，免得挡住画面。
python3 - "$APP/Contents/MacOS/WindowShade" "$DRIVER/Contents/MacOS/DemoDriver" <<'PY'
import datetime, os, plistlib, sys
path = os.path.expanduser("~/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist")
os.makedirs(os.path.dirname(path), exist_ok=True)
approvals = {}
if os.path.exists(path):
    with open(path, "rb") as f:
        approvals = plistlib.load(f)
until = datetime.datetime(2099, 1, 1)
for executable in sys.argv[1:]:
    approvals[executable] = until
for bundle in ["com.windowshade.prototype", "com.windowshade.demo-driver"]:
    approvals[bundle] = until
with open(path, "wb") as f:
    plistlib.dump(approvals, f)
print("approved", sorted(approvals))
PY
killall replayd 2>/dev/null || true

echo "==> launch"
defaults write com.windowshade.prototype ShadeOnboardingShown -bool true
printf '窗口卷帘的来历\n\nMac OS 8 时代，双击标题栏，窗口就卷成一条只剩标题栏的细条，留在原地。\n\nWindowShade 把这件事带回了 macOS。\n' > "$OUT/参考资料.txt"
open -a TextEdit "$OUT/参考资料.txt"
sleep 3
open "$APP"
sleep 6

echo "==> record"
open -W --stderr "$OUT/driver.log" "$DRIVER" --args "$OUT/demo.mp4"
cat "$OUT/driver.log" || true
cp ~/Library/Logs/WindowShade/windowshade.log "$OUT/windowshade.log" 2>/dev/null || true
grep -E "tap|>>> shade|corner|minimized|overlay|glance|verification|space:|screen:" "$OUT/windowshade.log" | tail -60 || true

screencapture -x "$OUT/end.png" 2>/dev/null || true
ls -la "$OUT"
test -s "$OUT/demo.mp4"
