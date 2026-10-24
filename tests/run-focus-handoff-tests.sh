#!/bin/bash
# 收起时把焦点交给哪个窗口：在模拟的窗口列表上检查（第 2 层组件测试）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/focus-handoff-tests
swiftc -parse-as-library prototype/Platform/WindowHider.swift prototype/Platform/ScreenLayout.swift \
  prototype/Platform/FocusHandoff.swift prototype/Domain/*.swift prototype/Core/CornerParking.swift \
  tests/support/TestSuite.swift tests/support/Fakes/FakeFocusControl.swift tests/FocusHandoffTests.swift \
  -o .build/focus-handoff-tests/focus
.build/focus-handoff-tests/focus
