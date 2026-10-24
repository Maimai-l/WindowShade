#!/bin/bash
# 领域层：应用程序配置表的匹配、收起计划的决定（纯函数，不调用系统接口）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/domain-tests
swiftc -parse-as-library prototype/Domain/*.swift tests/support/TestSuite.swift tests/DomainTests.swift \
  -o .build/domain-tests/domain
.build/domain-tests/domain
