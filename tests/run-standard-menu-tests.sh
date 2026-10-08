#!/bin/bash
# 标准菜单、收起窗口的菜单分区和“关于”面板（纯逻辑，不碰用户的设置和窗口）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/standard-menu-tests
swiftc -target "$(uname -m)-apple-macosx14.0" \
  prototype/App/StandardMenu.swift \
  tests/StandardMenuTests.swift -o .build/standard-menu-tests/menu
.build/standard-menu-tests/menu
