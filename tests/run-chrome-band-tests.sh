#!/bin/bash
# 卷帘条下沿的像素判定：合成的窗口顶部，纯计算，不需要任何权限。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/chrome-band-tests
swiftc -parse-as-library prototype/Core/ChromeBand.swift tests/support/TestSuite.swift tests/ChromeBandTests.swift \
  -o .build/chrome-band-tests/run
.build/chrome-band-tests/run
