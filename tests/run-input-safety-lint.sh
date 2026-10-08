#!/bin/bash
# 输入安全的源码检查（docs/testing.md 第 3.6 节 R6）。
#
# WindowShade 持有全系统的鼠标钩子。2026-10-08 关闭一个收起的、有未保存内容的文本编辑窗口时，
# 合成的鼠标事件、钩子无限等待主线程和对目标 App 的同步查询互相等待，全系统输入卡死，只能强制重启。
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

# 5. 钩子回调里问主线程只能经过 TapDecision（有硬时限）。
if grep -q 'decision.waitForSwallow()' prototype/App/EventTapCallback.swift \
   && ! grep -qE 'DispatchSemaphore|\.wait\(' prototype/App/EventTapCallback.swift; then
  echo "ok   the event tap asks the main thread only through TapDecision"
else
  echo "FAIL the event tap asks the main thread only through TapDecision"
  failed=$((failed + 1))
fi

if [ "$failed" -gt 0 ]; then
  echo "FAIL input-safety-lint: $failed check(s) failed"
  exit 1
fi
echo "PASS input-safety-lint"
