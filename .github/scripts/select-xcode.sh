#!/bin/bash
# Pick the newest installed Xcode.
set -euo pipefail
ls -d /Applications/Xcode*.app
xcode=$(ls -d /Applications/Xcode_*.app | sort -V | tail -1)
sudo xcode-select -s "$xcode"
xcodebuild -version
swiftc --version
