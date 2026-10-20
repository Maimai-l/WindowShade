#!/bin/bash
# 交给后台队列用的屏幕快照：换算、可见判断、挪进屏幕和读 NSScreen 的同名函数一致（tests/ScreenSnapshotTests.swift）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/screen-snapshot-tests
swiftc -parse-as-library prototype/Window/Coordinates.swift prototype/Platform/ScreenLayout.swift \
  prototype/Core/CornerParking.swift tests/support/TestSuite.swift tests/ScreenSnapshotTests.swift \
  -o .build/screen-snapshot-tests/tests
.build/screen-snapshot-tests/tests
