#!/bin/bash
# 一个点是否落在卷帘条显示出来的部分上，以及双击落在上面时鼠标钩子怎么处理（tests/StripHitTestTests.swift）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/strip-hit-test-tests
swiftc -parse-as-library prototype/Overlay/StripHitTest.swift tests/support/TestSuite.swift tests/StripHitTestTests.swift \
  -o .build/strip-hit-test-tests/tests
.build/strip-hit-test-tests/tests
