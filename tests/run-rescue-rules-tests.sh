#!/bin/bash
# 恢复记录在 WindowShade 运行期间的处理规则（tests/RescueRulesTests.swift）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/rescue-rules-tests
swiftc -parse-as-library prototype/Recovery/RestoreVerifier.swift prototype/Recovery/RescueRules.swift \
  prototype/Recovery/PreparingIntent.swift \
  tests/support/TestSuite.swift tests/RescueRulesTests.swift \
  -o .build/rescue-rules-tests/tests
.build/rescue-rules-tests/tests
