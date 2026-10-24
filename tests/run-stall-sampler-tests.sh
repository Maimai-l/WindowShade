#!/bin/bash
# 卡顿采样器：一次长卡顿分段采集多份调用栈（主线程真的阻塞 1.1 秒）；等输入的跟踪循环不记成卡顿。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/stall-sampler-tests
swiftc -parse-as-library prototype/Support/Diagnostics.swift prototype/Support/SecureLogFile.swift tests/StallSamplerTests.swift \
  -o .build/stall-sampler-tests/sampler
.build/stall-sampler-tests/sampler
