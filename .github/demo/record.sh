#!/bin/bash
# 在 CI 的 macOS 机器上编出 WindowShade、授权，录收起 / 看一眼 / 展开的视频：文本编辑和访达各一段。
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT="$PWD/.build/demo"
mkdir -p "$OUT"
# WINDOWSHADE_LOCAL=1：在自己的 Mac 上跑（.github/demo/run-on-this-mac.sh），不是 GitHub 的临时虚拟机。
# 那里系统完整性保护开着，不能直接写权限数据库：权限由用户在系统设置里给一次，这里只检查；
# 用固定的证书签名（WINDOWSHADE_TEST_SIGN_IDENTITY），重新编译后系统仍认得，权限不用再给。
LOCAL="${WINDOWSHADE_LOCAL:-0}"
SIGN_ID="${WINDOWSHADE_TEST_SIGN_IDENTITY:--}"
# 证书放在单独的钥匙串里时（run-on-this-mac.sh），只在那里找。
sign() { codesign --force ${WINDOWSHADE_TEST_KEYCHAIN:+--keychain "$WINDOWSHADE_TEST_KEYCHAIN"} -s "$SIGN_ID" "$@"; }
csrutil status || true
sw_vers
system_profiler SPDisplaysDataType | grep -E "Resolution|Display Type" || true

# RECORD_PART=reproduce-e13 时编的是修复之前的版本（f183ee4 的上一个提交），用来证明场景 E13
# 测得出 2026-10-08 用户遇到的全系统输入卡死（docs/testing.md 第 5 节）。其余情况编当前的代码。
SRC="$PWD"
if [ "${RECORD_PART:-all}" = "reproduce-e13" ]; then
  SRC="$PWD/.build/before-fix"
  rm -rf "$SRC"
  git worktree prune
  git worktree add --detach "$SRC" f183ee4^ || exit 1
fi

echo "==> build ($(git -C "$SRC" log -1 --format='%h %s' 2>/dev/null || cat "$SRC/KIT_VERSION" 2>/dev/null))"
WINDOWSHADE_CHECK_OUTPUT="$OUT/bin" "$SRC/prototype/build.sh" --check || exit 1

APP="$OUT/WindowShade.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$SRC/prototype/Info.plist" "$APP/Contents/Info.plist"
cp "$OUT/bin/WindowShade" "$APP/Contents/MacOS/WindowShade"
# 鼠标钩子进程（docs/design.md 第 5.9 节）。修复之前的版本没有它。
rm -f "$APP/Contents/MacOS/WindowShadeTapHelper"
if [ -f "$OUT/bin/WindowShadeTapHelper" ] && [ "$SRC" = "$PWD" ]; then
  cp "$OUT/bin/WindowShadeTapHelper" "$APP/Contents/MacOS/WindowShadeTapHelper"
  sign "$APP/Contents/MacOS/WindowShadeTapHelper"
fi
cp assets/app-icon/WindowShade.icns "$APP/Contents/Resources/" 2>/dev/null || true
ditto "$SRC/prototype/Vendor/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
sign --deep "$APP"
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
sign "$DRIVER"

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
sign "$PROBE"

if [ "$LOCAL" != "1" ]; then
echo "==> grant permissions"
sudo python3 .github/demo/grant-tcc.py \
  "com.windowshade.prototype=$APP" "com.windowshade.demo-driver=$DRIVER"
sudo killall tccd 2>/dev/null || true
fi
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

echo "==> prepare the desktop"
# 探测点击落在桌面上：关掉“点按墙纸显示桌面”，否则所有窗口被移开，还会弹出说明窗口挡住场景。
defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false
killall WindowManager 2>/dev/null || true
# ProbeApp 每个场景结束时被直接结束，P02 让它崩溃：不弹“意外退出”和“是否重新打开窗口”的对话框。
defaults write com.apple.CrashReporter DialogType none
defaults write com.windowshade.probe ApplePersistenceIgnoreState -bool true
rm -rf "$HOME/Library/Saved Application State/com.windowshade.probe.savedState"
killall Tips 2>/dev/null || true
# 第一次打开 Chrome 时系统弹“从互联网下载的应用程序”确认框（CoreServicesUIAgent），盖在测试窗口上，
# 结束它也会被系统重新弹出来。先去掉下载隔离属性，不让它出现。
for app in "/Applications/Google Chrome.app"; do
  [ -d "$app" ] && xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
done

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

# 本机运行：开跑前确认两个程序都有权限、用户登录在桌面、屏幕没锁、有显示器。缺什么就说出来并停下（退出码 3）。
if [ "$LOCAL" = "1" ]; then
  echo "==> preflight"
  open -W --stdout "$OUT/preflight.txt" --stderr "$OUT/preflight.log" "$DRIVER" --args preflight
  driver_ok=$?
  cat "$OUT/preflight.txt" 2>/dev/null || true
  shade_line=$(grep "permissions: accessibility=" ~/Library/Logs/WindowShade/windowshade.log 2>/dev/null | tail -1)
  echo "WindowShade: ${shade_line:-no permissions line in its log}"
  if ! grep -q "driver-missing= " "$OUT/preflight.txt" 2>/dev/null || [ "$driver_ok" != 0 ] \
     || ! echo "$shade_line" | grep -q "accessibility=true screenRecording=true"; then
    echo "PREFLIGHT FAILED"
    exit 3
  fi
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

# CI 把这份脚本分成几个并行任务（.github/workflows/demo.yml 的 matrix），RECORD_PART 说明这一个做哪部分：
#   recordings   录像（文本编辑、访达）、E13、检查的检查（K01 至 K05）、两个权限场景组
#   shard:i/n    主场景组里序号除以 n 余 i 的那些场景
#   random       随机操作 Q01（300 步，十几分钟，单独一个任务）
#   reproduce-e13  用修复之前的版本跑 E13、A34、X01 至 X05，至少一条要报出输入被挡住（测试测得出这类缺陷）
#   all（默认）  全部，本地运行用
PART="${RECORD_PART:-all}"
RECORDINGS=false
RANDOM_OPS=false
REPRODUCE=false
SHARD=""
case "$PART" in
  all) RECORDINGS=true; RANDOM_OPS=true; SHARD="main" ;;
  recordings) RECORDINGS=true ;;
  random) RANDOM_OPS=true ;;
  reproduce-e13) REPRODUCE=true ;;
  shard:*) SHARD="$PART" ;;
  *) echo "unknown RECORD_PART=$PART"; exit 1 ;;
esac
SCENARIO_RESULTS=()

if $RECORDINGS; then
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

# 检查的检查（docs/test-catalog.md 第 12 节）：故意制造违反，确认 I2、I3、I4、I5、I6 的检查报出来。
# K05（录像逐帧检查，I7）在下面和录像检查一起跑。
echo "==> checks of the checks: K01-K04, K06"
open -W --stderr "$OUT/driver-checks.log" "$DRIVER" --args "$OUT/checks.json" scenarios "$PROBE" "$APP" "K01,K02,K03,K04,K06"
cat "$OUT/driver-checks.log" || true
SCENARIO_RESULTS+=("$OUT/checks.json")
fi

# 用修复之前的版本跑 E13。那个版本会让整台机器不响应输入，驱动程序自己也可能停住：
# 看门狗不靠输入，120 秒后结束 WindowShade，再过 30 秒结束驱动程序，并留下标记。
if $REPRODUCE; then
  echo "==> scenario E13 against the build before the fix: it must report blocked input"
  rm -f "$OUT/watchdog-fired"
  ( sleep 120
    if pgrep -x DemoDriver >/dev/null; then
      echo "watchdog: E13 still running after 120 s; killing WindowShade"
      touch "$OUT/watchdog-fired"
      pkill -9 -x WindowShade
      sleep 30
      pkill -9 -x DemoDriver
    fi ) &
  watchdog=$!
  open -W --stderr "$OUT/driver-close-unsaved.log" "$DRIVER" --args "$OUT/close-unsaved.mp4" close-unsaved
  kill "$watchdog" 2>/dev/null
  cat "$OUT/driver-close-unsaved.log" || true
  # E13 在修复之前的版本上也通过了（7b36047）：旧版本只合成了一次点击，没有凑出卡死的条件。
  # 4b7e042 上 X01 至 X05 在旧版本上只报出合成输入（I3）和主线程停顿（I6），探测点击最慢 0.5 秒：
  # 旧代码合成点击时点击次数写死为 1，凑不成双击；主线程忙时钩子等 0.5 秒就放行。
  # 不限时等待的那条路是：主线程已经开始处理一次真的双击，又去问一个卡住的应用程序（旧版本每次最多等 6 秒）。
  # A34 正是这样：应用程序卡住 3 秒，双击它的标题栏，随后的探测点击应当被挡住。
  pgrep -x WindowShade >/dev/null || { open "$APP"; sleep 5; }
  ( sleep 420
    if pgrep -x DemoDriver >/dev/null; then
      echo "watchdog: A34, X01-X05 still running after 420 s; killing WindowShade"
      touch "$OUT/watchdog-fired"
      pkill -9 -x WindowShade
      sleep 30
      pkill -9 -x DemoDriver
    fi ) &
  watchdog=$!
  open -W --stderr "$OUT/driver-before-fix.log" "$DRIVER" --args "$OUT/before-fix.json" scenarios "$PROBE" "$APP" "A34,X01,X02,X03,X04,X05"
  kill "$watchdog" 2>/dev/null
  cat "$OUT/driver-before-fix.log" || true
fi

# 随机操作（docs/test-catalog.md 第 11 节）：每次运行用新的种子，种子写在结果里。
if $RANDOM_OPS; then
  echo "==> random operations: Q01"
  open -W --stderr "$OUT/driver-random.log" "$DRIVER" --args "$OUT/random.json" scenarios "$PROBE" "$APP" "Q01"
  cat "$OUT/driver-random.log" || true
  SCENARIO_RESULTS+=("$OUT/random.json")
fi

# 逐条场景和不变式检查（Scenarios*.swift）：每条一个新的 ProbeApp，跑完检查不变式。
if [ -n "$SHARD" ]; then
  echo "==> scenarios with invariant checks ($SHARD)"
  if [ "$SHARD" = "main" ]; then
    open -W --stderr "$OUT/driver-scenarios.log" "$DRIVER" --args "$OUT/scenarios.json" scenarios "$PROBE" "$APP"
  else
    open -W --stderr "$OUT/driver-scenarios.log" "$DRIVER" --args "$OUT/scenarios.json" scenarios "$PROBE" "$APP" "$SHARD"
  fi
  cat "$OUT/driver-scenarios.log" || true
  SCENARIO_RESULTS+=("$OUT/scenarios.json")
fi

# 权限场景组：收回一项权限，重启 WindowShade 后只跑这一组，跑完把权限还回去。
grant_all() {
  sudo python3 .github/demo/grant-tcc.py "com.windowshade.prototype=$APP" >/dev/null
  sudo killall tccd 2>/dev/null || true
}
run_group() {
  local name="$1" service="$2" ids="$3"
  echo "==> scenarios without $service: $ids"
  sudo python3 .github/demo/grant-tcc.py --revoke "$service" com.windowshade.prototype
  # 系统自带的收回方式也用一遍（用户和系统两份记录）：只删数据库时，辅助功能的授权在 CI 上仍然有效过。
  tccutil reset "$service" com.windowshade.prototype || true
  sudo tccutil reset "$service" com.windowshade.prototype || true
  # 旧版系统的“所有程序都可以用辅助功能”开关文件：存在时收回单个应用程序的授权无效，这一组跑完再放回。
  if [ "$service" = Accessibility ] && sudo test -e /private/var/db/.AccessibilityAPIEnabled; then
    echo "legacy accessibility switch present; moving it aside for this group"
    sudo mv /private/var/db/.AccessibilityAPIEnabled /private/var/db/.AccessibilityAPIEnabled.off
  fi
  sudo killall tccd 2>/dev/null || true
  sleep 2
  echo "remaining kTCCService$service rows for WindowShade:"
  for db in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
    sudo sqlite3 "$db" "select client, client_type, auth_value, auth_reason from access where service='kTCCService$service' and client like '%windowshade%'" 2>&1 | sed "s|^|  $db: |"
  done
  open -W --stderr "$OUT/driver-$name.log" "$DRIVER" --args "$OUT/$name.json" scenarios "$PROBE" "$APP" "$ids"
  cat "$OUT/driver-$name.log" || true
  if sudo test -e /private/var/db/.AccessibilityAPIEnabled.off; then
    sudo mv /private/var/db/.AccessibilityAPIEnabled.off /private/var/db/.AccessibilityAPIEnabled
  fi
  grant_all
}
if $RECORDINGS && [ "$LOCAL" = "1" ]; then
  # 收回、再给权限要直接改权限数据库，本机上做不到（系统完整性保护开着）。
  echo "SKIP A26, D08, A27, H09: they take a permission away and give it back, which needs the CI machine"
elif $RECORDINGS; then
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
SCENARIO_RESULTS+=("$OUT/scenarios-noscreen.json" "$OUT/scenarios-noax.json")
fi

cp ~/Library/Logs/WindowShade/windowshade.log "$OUT/windowshade.log" 2>/dev/null || true
collect_crashes
pgrep -x WindowShade >/dev/null || { echo "WindowShade exited during the recording"; exit 1; }
grep -E "tap|>>> shade|corner|minimized|overlay|glance|verification|space:|screen:|capture full|titlebar" "$OUT/windowshade.log" | tail -80 || true

screencapture -x "$OUT/end.png" 2>/dev/null || true
ls -la "$OUT"
status=0
if $RECORDINGS; then
test -s "$OUT/demo.mp4" && test -s "$OUT/demo-finder.mp4"

# 逐帧检查（docs/testing.md 第 6 节）：空帧、被别的窗口盖住、录屏指示器、展开后的位置和大小。
if command -v ffmpeg >/dev/null; then
echo "==> check the frame check (K05)"
bash tests/run-frame-check-selftest.sh || status=1
echo "==> check frames"
for name in demo demo-finder; do
  python3 .github/demo/check_frames.py "$OUT/$name.mp4" "$OUT/$name.json" "$OUT/windowshade.log" || status=1
done
else
  echo "SKIP K05 and the frame check: ffmpeg is not installed"
fi
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
fi
if $REPRODUCE; then
echo "==> check that the tests catch blocked input in the build before the fix"
python3 - "$OUT/close-unsaved.json" "$OUT/before-fix.json" "$OUT/watchdog-fired" <<'PY' || status=1
import json, os, sys
caught = []
if os.path.exists(sys.argv[3]):
    caught.append("the machine stopped taking input and the watchdog had to end WindowShade")
try:
    with open(sys.argv[1]) as f:
        e13 = json.load(f)
    print("E13:", json.dumps(e13, ensure_ascii=False))
    caught += ["E13: " + f for f in e13.get("failures", []) if "probe click" in f]
    if e13.get("passed"):
        print("E13 passed on the build before the fix: it does not reproduce the reported freeze")
except (OSError, ValueError) as error:
    print(f"E13: no result ({error})")
try:
    with open(sys.argv[2]) as f:
        suite = json.load(f)
    for s in suite["scenarios"]:
        print(("PASS " if s["passed"] else "FAIL ") + s["id"] + " " + s["title"])
        for v in s["violations"]:
            print("     " + v)
        caught += [s["id"] + ": " + v for v in s["violations"] if v.startswith("I2:")]
except (OSError, ValueError, KeyError) as error:
    print(f"A34, X01-X05: no result ({error})")
if caught:
    print("PASS before-fix: the tests catch blocked input in the build before the fix:")
    for c in caught:
        print("     " + c)
    sys.exit(0)
print("FAIL before-fix: no test caught blocked input in the build before the fix")
sys.exit(1)
PY
fi
grep -n "event-tap: main thread did not answer\|traffic: " "$OUT/windowshade.log" | tail -20 || true
echo "==> check scenarios"
# reproduce-e13 没有场景组结果：数组为空时 bash 3.2 在 set -u 下会报未定义，用 + 展开。
python3 - "${GITHUB_STEP_SUMMARY:-/dev/null}" ${SCENARIO_RESULTS[@]+"${SCENARIO_RESULTS[@]}"} <<'PY' || status=1
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
        skipped = s.get("notes", {}).get("skipped")
        verdict = "跳过" if skipped and s["passed"] else ("通过" if s["passed"] else "未通过")
        detail = skipped if skipped and s["passed"] else "<br>".join(s["violations"])
        rows.append(f"| {s['id']} | {s['title']} | {verdict} | {detail} |")
        label = "SKIP " if skipped and s["passed"] else ("PASS " if s["passed"] else "FAIL ")
        print(label + s["id"] + " " + s["title"] + (f" ({skipped})" if skipped and s["passed"] else ""))
        for v in s["violations"]:
            print("     " + v)
    failed += suite["failed"]
    if not suite.get("finished", True):
        print(f"FAIL {path}: the suite stopped before its last scenario")
        rows.append(f"| {path} | 没有跑完 | 未通过 | 场景组在最后一条之前停止 |")
        failed += 1
with open(sys.argv[1], "a") as summary:
    summary.write("\n".join(rows) + "\n")
sys.exit(0 if failed == 0 else 1)
PY
exit $status
