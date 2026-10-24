#!/bin/bash
# 恢复记录停在“准备”这一步时，重新启动后怎样处理那扇窗口（tests/PreparingIntentTests.swift）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/preparing-intent-tests
swiftc -parse-as-library prototype/Recovery/PreparingIntent.swift tests/support/TestSuite.swift tests/PreparingIntentTests.swift \
  -o .build/preparing-intent-tests/tests
.build/preparing-intent-tests/tests
