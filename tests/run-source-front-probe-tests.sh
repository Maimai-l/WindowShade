#!/bin/bash
# 展开后判断原窗口是否已排到最前：查窗口列表在后台队列上做，主线程不等窗口服务器（tests/SourceFrontProbeTests.swift）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/source-front-probe-tests
swiftc -parse-as-library prototype/Window/SourceFrontProbe.swift tests/support/TestSuite.swift tests/SourceFrontProbeTests.swift \
  -o .build/source-front-probe-tests/tests
.build/source-front-probe-tests/tests
