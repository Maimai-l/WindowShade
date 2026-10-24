#!/bin/bash
# 移开原窗口的顺序：在模拟窗口上检查各隐藏策略依次尝试的方式（第 2 层组件测试）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/window-hider-tests
swiftc -parse-as-library prototype/Domain/*.swift prototype/Core/CornerParking.swift \
  prototype/Platform/ScreenLayout.swift prototype/Platform/WindowHider.swift \
  tests/support/TestSuite.swift tests/support/Fakes/FakeWindowControl.swift tests/WindowHiderTests.swift \
  -o .build/window-hider-tests/hider
.build/window-hider-tests/hider
