#!/bin/bash
# 收起截图的短时缓存：过期的图到时清掉，不一直占着内存（tests/WindowSnapshotCacheTests.swift）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/window-snapshot-cache-tests
swiftc -parse-as-library prototype/Capture/WindowSnapshotCache.swift tests/support/TestSuite.swift \
  tests/WindowSnapshotCacheTests.swift -o .build/window-snapshot-cache-tests/tests
.build/window-snapshot-cache-tests/tests
