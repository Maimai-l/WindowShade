#!/bin/bash
# 备用池：窗口用完不销毁，放在这里下次直接拿来用（tests/SpareWindowPoolTests.swift）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/spare-window-pool-tests
swiftc -parse-as-library prototype/Overlay/SpareWindowPool.swift tests/support/TestSuite.swift tests/SpareWindowPoolTests.swift \
  -o .build/spare-window-pool-tests/tests
.build/spare-window-pool-tests/tests
