#!/bin/bash
# Pick the newest installed Xcode and make sure the Metal toolchain is present.
set -euo pipefail
ls -d /Applications/Xcode*.app
xcode=$(ls -d /Applications/Xcode_*.app | sort -V | tail -1)
sudo xcode-select -s "$xcode"
xcodebuild -version
swiftc --version
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  xcodebuild -downloadComponent MetalToolchain
fi
xcrun -sdk macosx metal --version
