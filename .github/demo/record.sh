#!/bin/bash
# 在 CI 的 macOS 机器上编出 WindowShade、授权，录收起 / 看一眼 / 展开的视频：文本编辑和访达各一段。
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
# 截图耗时诊断：转移焦点之前先截一次并记下耗时（App/ShadeController.swift）。
defaults write com.windowshade.prototype WindowShadeDiagnoseCapture -bool true
printf '窗口卷帘的来历\n\nMac OS 8 时代，双击标题栏，窗口就卷成一条只剩标题栏的细条，留在原地。\n\nWindowShade 把这件事带回了 macOS。\n' > "$OUT/参考资料.txt"
open -a TextEdit "$OUT/参考资料.txt"
sleep 3
open "$APP"
sleep 6
collect_crashes() {
  cp ~/Library/Logs/DiagnosticReports/WindowShade* "$OUT/" 2>/dev/null || true
  for report in "$OUT"/WindowShade*.ips; do [ -f "$report" ] && head -80 "$report"; done
}
# 没在跑就别录了：录出来只是系统自己的双击缩放，看着像通过。
if ! pgrep -x WindowShade >/dev/null; then
  echo "WindowShade is not running after launch"
  collect_crashes
  exit 1
fi

# 录一段。ReplayKit 偶尔在第一帧报 -5822，录像文件不完整，App 本身没有问题：
# 这种情况重录一次，并在日志里写明；第二次仍然失败就让 CI 失败。
record() {
  local log="$1"; shift
  open -W --stderr "$log" "$DRIVER" --args "$@"
  cat "$log" || true
  if grep -q "recording failed" "$log"; then
    echo "recording failed (ReplayKit), recording this scenario once more"
    open -W --stderr "$log" "$DRIVER" --args "$@"
    cat "$log" || true
  fi
}

echo "==> record TextEdit"
record "$OUT/driver.log" "$OUT/demo.mp4"

# 访达：工具栏比普通标题栏高一倍多，窗口也更宽；双击点放在工具栏按钮上面的空白。
echo "==> record Finder"
open /Applications
sleep 3
record "$OUT/driver-finder.log" "$OUT/demo-finder.mp4" com.apple.finder 900 500 8

cp ~/Library/Logs/WindowShade/windowshade.log "$OUT/windowshade.log" 2>/dev/null || true
collect_crashes
pgrep -x WindowShade >/dev/null || { echo "WindowShade exited during the recording"; exit 1; }
grep -E "tap|>>> shade|corner|minimized|overlay|glance|verification|space:|screen:|capture full|titlebar" "$OUT/windowshade.log" | tail -80 || true

screencapture -x "$OUT/end.png" 2>/dev/null || true
ls -la "$OUT"
test -s "$OUT/demo.mp4" && test -s "$OUT/demo-finder.mp4"

# 逐帧检查（docs/testing.md 第 6 节）：空帧、被别的窗口盖住、录屏指示器、展开后的位置和大小。
echo "==> check frames"
status=0
for name in demo demo-finder; do
  python3 .github/demo/check_frames.py "$OUT/$name.mp4" "$OUT/$name.json" "$OUT/windowshade.log" || status=1
done
exit $status
