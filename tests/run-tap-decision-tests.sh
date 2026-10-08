#!/bin/bash
# 全局鼠标钩子问主线程的硬时限：注入卡住的主线程（纯逻辑，不装钩子）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tap-decision-tests
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  prototype/Core/TapDecision.swift tests/support/TestSuite.swift tests/TapDecisionTests.swift \
  -o .build/tap-decision-tests/tap-decision
.build/tap-decision-tests/tap-decision
