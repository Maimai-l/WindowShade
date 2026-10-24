#!/bin/bash
# 脚本要在 macOS 自带的 bash 3.2 上跑（测试包的 run.sh、record.sh、build.sh）。
# bash 3.2 把变量名后面紧跟的中文当成变量名的一部分：2026-10-09 run-on-this-mac.sh 在用户的 Mac 上报
# “key: unbound variable”。变量后面紧跟非 ASCII 字符时，一律写成带花括号的形式。
set -uo pipefail
cd "$(dirname "$0")/.."
hits=$(perl -ne 'print "$ARGV:$.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/; close ARGV if eof' \
  prototype/build.sh .github/demo/*.sh .github/scripts/*.sh tests/*.sh)
if [ -n "$hits" ]; then
  echo "FAIL a variable is followed directly by a non-ASCII character (bash 3.2 reads it as part of the name):"
  echo "$hits" | sed 's/^/     /'
  exit 1
fi
echo "PASS shell-portability: no variable is followed directly by a non-ASCII character"
