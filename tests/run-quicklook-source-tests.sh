#!/bin/bash
# 访达快速查看面板显示的文件：按文件名找访达里选中的那一项，文件引用换成路径（场景 A32）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/quicklook-source-tests
swiftc -parse-as-library prototype/Window/QuickLookSource.swift tests/support/TestSuite.swift tests/QuickLookSourceTests.swift \
  -o .build/quicklook-source-tests/tests
.build/quicklook-source-tests/tests
