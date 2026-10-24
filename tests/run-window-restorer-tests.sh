#!/bin/bash
# 放回原窗口的顺序，以及应用程序无响应时调用方不等待（第 2 层组件测试）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/window-restorer-tests
swiftc -parse-as-library prototype/Domain/*.swift prototype/Core/CornerParking.swift \
  prototype/Platform/ScreenLayout.swift prototype/Platform/WindowHider.swift prototype/Platform/WindowRestorer.swift \
  tests/support/TestSuite.swift tests/support/Fakes/FakeRestoreControl.swift tests/WindowRestorerTests.swift \
  -o .build/window-restorer-tests/restorer
.build/window-restorer-tests/restorer
