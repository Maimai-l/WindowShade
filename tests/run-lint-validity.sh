#!/bin/bash
# 静态检查的有效性（docs/testing.md 第 5.1 节）：有的缺陷靠静态检查的某一条防止再次出现，
# 这一条要在修复之前的源码上报出，在当前代码上通过，才说明它查的正是那个缺陷。
# 修复提交的上一个提交里的 prototype/ 用 git archive 取出，把当前的检查脚本复制进去，在这份源码上运行。
# 需要仓库里有修复提交和它的上一个提交；浅克隆里没有时向 origin 取。
set -uo pipefail
cd "$(dirname "$0")/.."

# 每行一条：名称|修复提交|检查脚本|检查脚本里这一条的说明（报出时跟在 FAIL 后面，通过时跟在 ok 后面）
ROWS=(
  "login-item-main-thread|d910ac1|run-input-safety-lint.sh|the login item is queried and registered only off the main thread"
  "mouse-tap-in-process|b1a164f|run-input-safety-lint.sh|the mouse tap lives in the tap helper and asks WindowShade with time limits"
  "window-list-on-main-after-unfold|5e6eca7|run-input-safety-lint.sh|the per-frame wait after unfolding reads the window list off the main thread"
)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0

for row in "${ROWS[@]}"; do
  IFS='|' read -r name fix script check <<<"$row"
  if ! git cat-file -e "${fix}^{commit}" 2>/dev/null || ! git cat-file -e "${fix}^^{commit}" 2>/dev/null; then
    git fetch -q --depth=2 origin "$fix" 2>/dev/null
  fi
  if ! git cat-file -e "${fix}^^{commit}" 2>/dev/null; then
    echo "FAIL $name: the commit before ${fix} is not in this repository"
    failed=$((failed + 1))
    continue
  fi
  old="$work/$name"
  mkdir -p "$old/tests"
  git archive "${fix}^" prototype | tar -x -C "$old"
  cp "tests/$script" "$old/tests/$script"
  before=$(bash "$old/tests/$script" 2>&1)
  after=$(bash "tests/$script" 2>&1)
  if ! grep -qF "FAIL $check" <<<"$before"; then
    echo "FAIL $name: $script did not report \"$check\" on ${fix}^"
    failed=$((failed + 1))
  elif ! grep -qF "ok   $check" <<<"$after"; then
    echo "FAIL $name: $script still reports \"$check\" on the current code"
    failed=$((failed + 1))
  else
    echo "ok   $name: $script reports it on ${fix}^ and passes on the current code"
  fi
done

if [ "$failed" -gt 0 ]; then
  echo "FAIL lint-validity: $failed check(s) failed"
  exit 1
fi
echo "PASS lint-validity"
