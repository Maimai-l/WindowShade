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
# 给人下载试用：ditto 打包保留框架里的符号链接和可执行权限（GitHub 自己打包会丢掉这两样）。
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/WindowShade-app.zip"

DRIVER="$OUT/DemoDriver.app"
rm -rf "$DRIVER"
mkdir -p "$DRIVER/Contents/MacOS"
swiftc -swift-version 5 -parse-as-library -O .github/demo/*.swift \
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

# 故障注入用的测试应用程序（docs/test-catalog.md 第 10 节）：行为由启动参数控制，结果确定。
PROBE="$OUT/ProbeApp.app"
rm -rf "$PROBE"
mkdir -p "$PROBE/Contents/MacOS"
swiftc -swift-version 5 -O .github/demo/probe/ProbeApp.swift -o "$PROBE/Contents/MacOS/ProbeApp" -framework AppKit || exit 1
cat > "$PROBE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.windowshade.probe</string>
<key>CFBundleExecutable</key><string>ProbeApp</string>
<key>CFBundleName</key><string>ProbeApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force -s - "$PROBE"

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
# CI 虚拟机上窗口的第一次整窗截图要 0.6–1.7 秒，真实的 Mac 上只要几十毫秒：启动时先截一次最前面的窗口，
# 让录像里的收起耗时和真实的 Mac 一致（WindowShade.swift 的 prewarmFastCapture，docs/testing.md 第 5 节）。
defaults write com.windowshade.prototype WindowShadePrewarmFullCapture -bool true
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

# 场景 E13：关闭一个收起的、有未保存内容的文本编辑窗口（2026-10-08 曾让整台 Mac 不响应输入）。
# 驱动程序自己新建文档、打字、收起、点卷帘条上的关闭按钮、在“是否保存”里选删除，并不停地发探测点击。
# 不重录：重录时文档已经关掉了。结果在 close-unsaved.json，下面检查。
echo "==> scenario E13: close a folded window with unsaved changes"
open -W --stderr "$OUT/driver-close-unsaved.log" "$DRIVER" --args "$OUT/close-unsaved.mp4" close-unsaved
cat "$OUT/driver-close-unsaved.log" || true

# 逐条场景和不变式检查（Scenarios.swift）：ProbeApp 卡住、弹提示框、关闭超时、没有按钮、退出、崩溃，连点。
echo "==> scenarios with invariant checks"
open -W --stderr "$OUT/driver-scenarios.log" "$DRIVER" --args "$OUT/scenarios.json" scenarios "$PROBE" "$APP"
cat "$OUT/driver-scenarios.log" || true

# 权限场景组：收回一项权限，重启 WindowShade 后只跑这一组，跑完把权限还回去。
grant_all() {
  sudo python3 .github/demo/grant-tcc.py "com.windowshade.prototype=$APP" >/dev/null
  sudo killall tccd 2>/dev/null || true
}
run_group() {
  local name="$1" service="$2" ids="$3"
  echo "==> scenarios without $service: $ids"
  sudo python3 .github/demo/grant-tcc.py --revoke "$service" com.windowshade.prototype
  sudo killall tccd 2>/dev/null || true
  sleep 2
  open -W --stderr "$OUT/driver-$name.log" "$DRIVER" --args "$OUT/$name.json" scenarios "$PROBE" "$APP" "$ids"
  cat "$OUT/driver-$name.log" || true
  grant_all
}
run_group scenarios-noscreen ScreenCapture "A26,D08"
# H09 在场景中途要求授予辅助功能：驱动程序建 /tmp/windowshade-e2e-grant-accessibility，这里授权后回一个 .done。
rm -f /tmp/windowshade-e2e-grant-accessibility /tmp/windowshade-e2e-grant-accessibility.done
(
  for _ in $(seq 1 600); do
    if [ -f /tmp/windowshade-e2e-grant-accessibility ]; then
      grant_all
      touch /tmp/windowshade-e2e-grant-accessibility.done
      break
    fi
    sleep 1
  done
) &
GRANT_WATCHER=$!
run_group scenarios-noax Accessibility "A27,H09"
kill "$GRANT_WATCHER" 2>/dev/null || true
# 权限还回去以后，WindowShade 要重启才用得上；后面的检查要求它还在运行。
pkill -x WindowShade 2>/dev/null || true
sleep 1
open "$APP"
sleep 3

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
echo "==> check scenario E13"
python3 - "$OUT/close-unsaved.json" <<'PY' || status=1
import json, sys
try:
    with open(sys.argv[1]) as f:
        result = json.load(f)
except (OSError, ValueError) as error:
    print(f"FAIL E13: no result ({error})")
    sys.exit(1)
print(json.dumps(result, ensure_ascii=False, indent=1))
if not result.get("passed"):
    print("FAIL E13:", "; ".join(result.get("failures", [])))
    sys.exit(1)
print("PASS E13: save sheet once, window closed, worst probe %.3f s" % result.get("probeWorstLatency", 0))
PY
grep -n "event-tap: main thread did not answer\|traffic: " "$OUT/windowshade.log" | tail -20 || true
echo "==> check scenarios"
python3 - "${GITHUB_STEP_SUMMARY:-/dev/null}" "$OUT/scenarios.json" "$OUT/scenarios-noscreen.json" "$OUT/scenarios-noax.json" <<'PY' || status=1
import json, sys
rows = ["| 场景 | 内容 | 结果 | 违反的不变式 |", "|---|---|---|---|"]
failed = 0
for path in sys.argv[2:]:
    try:
        with open(path) as f:
            suite = json.load(f)
    except (OSError, ValueError) as error:
        print(f"FAIL {path}: no result ({error})")
        rows.append(f"| {path} | 没有结果 | 未通过 | {error} |")
        failed += 1
        continue
    for s in suite["scenarios"]:
        verdict = "通过" if s["passed"] else "未通过"
        rows.append(f"| {s['id']} | {s['title']} | {verdict} | {'<br>'.join(s['violations'])} |")
        print(("PASS " if s["passed"] else "FAIL ") + s["id"] + " " + s["title"])
        for v in s["violations"]:
            print("     " + v)
    failed += suite["failed"]
with open(sys.argv[1], "a") as summary:
    summary.write("\n".join(rows) + "\n")
sys.exit(0 if failed == 0 else 1)
PY
exit $status
