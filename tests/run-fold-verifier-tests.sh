#!/bin/bash
# 收起验证（prototype/Core/FoldVerifier.swift、FoldCallbackStamp.swift）：纯逻辑，不碰窗口。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/fold-verifier-tests
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" prototype/Core/FoldVerifier.swift prototype/Core/FoldCallbackStamp.swift \
  tests/support/TestSuite.swift tests/FoldVerifierTests.swift -o .build/fold-verifier-tests/tests
.build/fold-verifier-tests/tests
