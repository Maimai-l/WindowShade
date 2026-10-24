#!/bin/bash
# 角落停放：选哪个角、露出多少才算看得见（纯几何，不动任何窗口）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/corner-parking-tests
swiftc -parse-as-library prototype/Core/CornerParking.swift tests/CornerParkingTests.swift \
  -o .build/corner-parking-tests/parking
.build/corner-parking-tests/parking
