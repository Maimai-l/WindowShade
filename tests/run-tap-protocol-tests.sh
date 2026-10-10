#!/bin/bash
# 鼠标钩子进程和 WindowShade 之间的询问（prototype/Core/TapProtocol.swift）：纯逻辑，不装钩子。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tap-protocol-tests
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" prototype/Core/TapProtocol.swift tests/support/TestSuite.swift tests/TapProtocolTests.swift \
  -o .build/tap-protocol-tests/tests
.build/tap-protocol-tests/tests
