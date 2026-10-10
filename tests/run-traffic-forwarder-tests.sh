#!/bin/bash
# 卷帘条红绿灯转给原窗口：每个动作至多按一次（第 2 层组件测试，模拟窗口）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/traffic-forwarder-tests
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  prototype/Platform/TrafficForwarder.swift tests/support/TestSuite.swift tests/TrafficForwarderTests.swift \
  -o .build/traffic-forwarder-tests/forwarder
.build/traffic-forwarder-tests/forwarder
