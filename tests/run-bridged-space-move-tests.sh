#!/bin/bash
# 按住卷帘条切换桌面时用的 SkyLight 内部类：先确认它响应这个初始化方法再发消息（prototype/Private/BridgedSpaceMove.swift）。纯逻辑，不移动窗口。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/bridged-space-move-tests
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  prototype/Private/BridgedSpaceMove.swift tests/support/TestSuite.swift tests/BridgedSpaceMoveTests.swift \
  -o .build/bridged-space-move-tests/tests
.build/bridged-space-move-tests/tests
