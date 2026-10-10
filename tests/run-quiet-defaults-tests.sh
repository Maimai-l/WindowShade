#!/bin/bash
# 快捷键：新安装时不设置快捷键，升级时保留原有快捷键；录制规则和菜单上的按键（纯逻辑，不碰用户的设置和窗口）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/quiet-defaults-tests
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  prototype/App/GlobalShortcuts.swift prototype/App/HotKey.swift \
  tests/QuietDefaultsTests.swift -o .build/quiet-defaults-tests/quiet
.build/quiet-defaults-tests/quiet
