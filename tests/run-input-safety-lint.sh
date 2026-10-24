#!/bin/bash
# 输入安全的源码检查（docs/testing.md 第 3.6 节 R6）。
#
# WindowShade 持有全系统的鼠标钩子。2026-10-08 关闭一个收起的、有未保存内容的文本编辑窗口时，
# 合成的鼠标事件、钩子无限等待主线程和对目标 App 的同步查询互相等待，全系统输入停止响应，只能强制重启。
# 这里逐条禁止会造成这类后果的写法，出现一处就失败。
set -uo pipefail
cd "$(dirname "$0")/.."
failed=0

forbid() {
  local pattern="$1" reason="$2"
  local hits
  hits=$(grep -rnE --include='*.swift' "$pattern" prototype | grep -v '^prototype/Vendor/' || true)
  if [ -n "$hits" ]; then
    echo "FAIL $reason"
    echo "$hits" | sed 's/^/     /'
    failed=$((failed + 1))
  else
    echo "ok   $reason"
  fi
}

# 1. 不合成任何输入事件：不向系统或某个进程发鼠标、键盘事件。
forbid '\.post\(tap:' "no synthetic events posted to an event tap (CGEvent.post)"
forbid 'postToPid' "no synthetic events posted to a process (CGEvent.postToPid)"
forbid 'CGEventPost|CGPostMouseEvent|CGPostKeyboardEvent|CGPostScrollWheelEvent' "no legacy event posting APIs"
forbid 'CGEvent\((mouseEventSource|keyboardEventSource|scrollWheelEvent2Source)' "no synthetic mouse, keyboard or scroll events are created"
forbid 'dlsym\(.*"[A-Za-z]*(Post|Warp|Cursor|Associate|EventCreate|EventTap)[A-Za-z]*"' "no input or cursor functions looked up by name (dlsym)"

# 2. 不动用户的光标。
forbid 'CGWarpMouseCursorPosition|CGDisplayMoveCursorToPoint|CGAssociateMouseAndMouseCursorPosition' "the pointer is never moved or detached from the mouse"

# 3. 钩子线程不无限等待：等待一律带时限。
forbid '\.wait\(\)' "no unbounded semaphore or group waits"

# 4. 每次辅助功能调用都有短超时（启动时设到系统级元素上）。
if grep -q 'AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axMessagingTimeout)' prototype/WindowShade.swift \
   && grep -qE '^let axMessagingTimeout: Float = (0\.[0-9]+|1\.0)$' prototype/WindowShade.swift; then
  echo "ok   accessibility calls time out within 1 second"
else
  echo "FAIL accessibility calls time out within 1 second (axMessagingTimeout on the system-wide element)"
  failed=$((failed + 1))
fi

# 5. 钩子回调里问主线程只能经过 TapDecision（有固定时限）。
if grep -q 'decision.waitForSwallow()' prototype/App/EventTapCallback.swift \
   && ! grep -qE 'DispatchSemaphore|\.wait\(' prototype/App/EventTapCallback.swift; then
  echo "ok   the event tap asks the main thread only through TapDecision"
else
  echo "FAIL the event tap asks the main thread only through TapDecision"
  failed=$((failed + 1))
fi

# 6. 钩子放在单独的钩子进程里（docs/design.md 第 5.9 节）：WindowShade 停住时也不挡全系统的点击。
#    钩子进程问 WindowShade 只经过 CFMessagePortSendRequest，送出和等回话都有时限；回调里不做会久等的事。
HELPER=prototype/TapHelper/main.swift
if grep -q 'TapHelperLink.start()' prototype/WindowShade.swift \
   && grep -q 'TapProtocol.waits(eventAge:' "$HELPER" && grep -q 'waits.send, waits.reply' "$HELPER" \
   && ! grep -qE 'AXUIElement|DispatchSemaphore|Thread\.sleep|usleep|\.wait\(|NSApplication|import (AppKit|Cocoa)' "$HELPER"; then
  echo "ok   the mouse tap lives in the tap helper and asks WindowShade with time limits"
else
  echo "FAIL the mouse tap lives in the tap helper and asks WindowShade with time limits"
  failed=$((failed + 1))
fi

# 7. 主线程不向系统查询登录项：查一次要等系统的后台服务，2026-10-09 CI 上打开设置窗口时主线程因此停了 0.6 至 0.7 秒。
#    登录项只在 App/LaunchAtLogin.swift 里、在后台线程上查询和注册。
hits=$(grep -rn --include='*.swift' 'SMAppService' prototype | grep -v '^prototype/Vendor/' | grep -v '^prototype/App/LaunchAtLogin.swift:' || true)
if [ -z "$hits" ] && grep -q 'DispatchQueue.global' prototype/App/LaunchAtLogin.swift; then
  echo "ok   the login item is queried and registered only off the main thread"
else
  echo "FAIL the login item is queried and registered only off the main thread (App/LaunchAtLogin.swift)"
  [ -n "$hits" ] && echo "$hits" | sed 's/^/     /'
  failed=$((failed + 1))
fi

# 8. 主线程不查窗口列表来判断展开后原窗口是否已排到最前：撤卷帘条、结束“看一眼”的每帧循环里，只经 SourceFrontProbe
#    发起查询、读结果，查询放在后台队列上（Window/SourceFrontProbe.swift）。窗口服务器正忙时查一次要等它，
#    2026-10-17 CI 场景 L01 里这样一次查询让主线程停了 530 毫秒。
loops=$(awk '/func dismissOverlayWhenSourceInFront|func finishWhenSourceInFront/,/^    }$/' \
  prototype/App/FoldTransaction.swift prototype/App/Glance.swift)
if grep -q 'probe.poll()' <<<"$loops" \
   && ! grep -qE 'CGWindowListCopyWindowInfo|cgWindowInfo|WindowListCache|sourceIsInFront|sourceAppIsActive' <<<"$loops"; then
  echo "ok   the per-frame wait after unfolding reads the window list off the main thread"
else
  echo "FAIL the per-frame wait after unfolding reads the window list off the main thread (Window/SourceFrontProbe.swift)"
  failed=$((failed + 1))
fi

# 9. 打开“看一眼”时不新建面板：面板只在 GlanceController.panels 这个备用池里建，用完放回
#    （Overlay/SpareWindowPool.swift）。新建窗口要等窗口服务器回话，2026-10-17 CI 场景 A33-Safari 里等了 1,113 毫秒。
hits=$(grep -rn --include='*.swift' 'GlancePanel(' prototype | grep -v '^prototype/Vendor/' \
  | grep -v 'SpareWindowPool<GlancePanel>' || true)
if [ -z "$hits" ]; then
  echo "ok   the glance panel is reused, not made when a strip is clicked"
else
  echo "FAIL the glance panel is reused, not made when a strip is clicked (Overlay/SpareWindowPool.swift)"
  echo "$hits" | sed 's/^/     /'
  failed=$((failed + 1))
fi

# 10. 鼠标钩子每隔几秒查一次是否还开着（CGEvent.tapIsEnabled），关了就重新打开：回调超时或因用户输入，系统会停用钩子，
#     有时不发 tapDisabledBy* 事件。钩子进程和 WindowShade 自己的备用钩子都要查。依据：上游 surfine/WindowShade 31047b0。
if grep -q 'CGEvent.tapIsEnabled' "$HELPER" && grep -q 'CGEvent.tapIsEnabled' prototype/WindowShade.swift; then
  echo "ok   the mouse tap is checked every few seconds and turned back on when the system turned it off"
else
  echo "FAIL the mouse tap is checked every few seconds and turned back on when the system turned it off"
  failed=$((failed + 1))
fi

if [ "$failed" -gt 0 ]; then
  echo "FAIL input-safety-lint: $failed check(s) failed"
  exit 1
fi
echo "PASS input-safety-lint"
