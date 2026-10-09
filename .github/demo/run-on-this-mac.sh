#!/bin/bash
# 在自己的 Mac 上跑全部场景测试，不经过 GitHub（docs/testing.md 第 7 节）。
#
# 用法（在解开的测试包目录里）：
#   bash run.sh             全部：录像、检查的检查、主场景组、随机操作，约一小时
#   bash run.sh shard:0/3   只跑主场景组的三分之一（同 CI 的 RECORD_PART）
# 结果：~/WindowShadeTests/results-<时刻>.zip，把它发回给 Claude。
#
# 第一次运行会停在“权限”这一步：按提示在系统设置里打开开关，再运行一次。以后换新的测试包也不用再给，
# 因为两个程序都用同一张测试证书签名（放在单独的钥匙串 windowshade-test.keychain-db 里，不碰登录钥匙串）。
# 测试会改几项系统设置（双击标题栏的动作、程序坞位置、台前调度、深浅色外观等），跑完按原值改回。
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
STAMP=$(date +%Y%m%d-%H%M%S)
RESULTS="$HOME/WindowShadeTests"
mkdir -p "$RESULTS"
RUN_LOG="$RESULTS/run-$STAMP.log"
exec > >(tee "$RUN_LOG") 2>&1

say() { printf '\n==> %s\n' "$*"; }
stop() { printf '\n停止：%s\n' "$*"; exit 2; }

say "检查这台 Mac"
[ "$(uname)" = Darwin ] || stop "这个脚本只能在 macOS 上运行。"
console_user=$(stat -f %Su /dev/console)
[ "$console_user" = "$(id -un)" ] || stop "桌面上登录的是 ${console_user}，不是 $(id -un)。测试要操作桌面上的窗口：用屏幕共享以 $(id -un) 登录一次，并在“系统设置 → 用户与群组”里设为自动登录。"
xcrun --find swiftc >/dev/null 2>&1 || stop "没有 Swift 编译器。运行 xcode-select --install，或安装 Xcode 26。"
swift_version=$(xcrun swiftc --version 2>&1 | head -1)
echo "$swift_version"
echo "$swift_version" | grep -qE "Swift version ([6-9]|[1-9][0-9])\." || stop "需要 Swift 6 或更新的编译器（Xcode 26 或对应的命令行工具）。"
if pgrep -x WindowShade >/dev/null; then
  stop "WindowShade 正在运行。先从菜单栏退出它（会先展开全部收起的窗口），再运行。"
fi
command -v ffmpeg >/dev/null || echo "没有 ffmpeg：录像的逐帧检查（K05 等）会跳过，其余照常。"
sw_vers
sysctl -n hw.model
system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Resolution|Display Type|Online" || true

# 测试证书：自签名、只用来给测试用的程序签名。放在单独的钥匙串里，密码固定，不需要输入登录密码。
say "测试证书"
KEYCHAIN="$HOME/Library/Keychains/windowshade-test.keychain-db"
KEYCHAIN_PASSWORD="windowshade-test"
CERT_NAME="WindowShade Test Signing"
if [ ! -f "$KEYCHAIN" ]; then
  work=$(mktemp -d)
  cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null \
    && /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/id.p12" \
       -passout pass:"$KEYCHAIN_PASSWORD" \
    && security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" \
    && security set-keychain-settings "$KEYCHAIN" \
    && security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" \
    && security import "$work/id.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" -T /usr/bin/codesign >/dev/null \
    && security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null \
    || echo "建测试证书失败，改用临时签名。"
  rm -rf "$work"
fi
SIGN_ID="-"
try_sign() {  # 用测试证书签一个临时文件，成功返回 0；失败时把 codesign 的原话打出来
  local probe_bin
  probe_bin=$(mktemp)
  cp /usr/bin/true "$probe_bin"
  codesign --force --keychain "$KEYCHAIN" -s "$cert_hash" "$probe_bin"
  local result=$?
  rm -f "$probe_bin"
  return $result
}
if [ -f "$KEYCHAIN" ]; then
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  cert_hash=$(security find-certificate -c "$CERT_NAME" -Z "$KEYCHAIN" 2>/dev/null | awk '/SHA-1/ {print $NF}')
  if [ -n "$cert_hash" ] && try_sign; then
    SIGN_ID="$cert_hash"
  elif [ -n "$cert_hash" ]; then
    # 自签名证书要先被信任（只用于代码签名），codesign 才肯用。改信任设置时系统会在屏幕上要一次本机登录密码：
    # 用屏幕共享输入。只在这台 Mac 上做一次，以后的测试包都不再问。
    echo "测试证书还没被信任。屏幕上会弹出“修改证书信任设置”的密码框，用屏幕共享输入一次本机登录密码。"
    cert_file=$(mktemp)
    security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN" > "$cert_file"
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$cert_file"
    rm -f "$cert_file"
    if try_sign; then SIGN_ID="$cert_hash"; fi
  fi
fi
if [ "$SIGN_ID" != "-" ]; then
  echo "用测试证书签名（${SIGN_ID}）"
fi
if [ "$SIGN_ID" = "-" ]; then
  echo "测试证书用不了，改用临时签名：每换一个测试包，都要在系统设置里重新给一次权限。"
fi

# 测试会改的系统设置：先记下原值，结束时（包括中途出错、按 Control-C）改回。
say "记下会被改动的系统设置"
SAVED_FILE="$RESULTS/.saved-settings-$STAMP"
: > "$SAVED_FILE"
# 原来没有的键记成 ABSENT，恢复时删掉；不能记成空值（空值去 defaults write 会失败，只打出用法说明）。
remember() {  # 域 键 类型
  local value
  if value=$(defaults read "$1" "$2" 2>/dev/null); then
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$value" >> "$SAVED_FILE"
  else
    printf '%s\t%s\t%s\tABSENT\n' "$1" "$2" "$3" >> "$SAVED_FILE"
  fi
}
remember -g AppleActionOnDoubleClick string
remember com.apple.dock orientation string
remember com.apple.WindowManager GloballyEnabled bool
remember com.apple.WindowManager EnableStandardClickToShowDesktop bool
remember com.apple.CrashReporter DialogType string
APPEARANCE=light
[ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" = Dark ] && APPEARANCE=dark
WS_DEFAULTS="$RESULTS/.windowshade-defaults-$STAMP.plist"
defaults export com.windowshade.prototype "$WS_DEFAULTS" 2>/dev/null || rm -f "$WS_DEFAULTS"
cat "$SAVED_FILE"
echo "外观：$APPEARANCE"

RESTORED=0
restore() {
  [ "$RESTORED" = 1 ] && return
  RESTORED=1
  say "改回系统设置"
  pkill -x WindowShade 2>/dev/null || true
  pkill -x DemoDriver 2>/dev/null || true
  while IFS=$'\t' read -r domain key type value; do
    if [ "$value" = ABSENT ]; then
      defaults delete "$domain" "$key" 2>/dev/null || true
      echo "  删除 ${domain} ${key}（原来没有）"
    elif [ -n "$value" ]; then
      defaults write "$domain" "$key" "-$type" "$value"
      echo "  $domain $key = $value"
    fi
  done < "$SAVED_FILE"
  rm -f "$SAVED_FILE"
  if [ -f "$WS_DEFAULTS" ]; then
    defaults import com.windowshade.prototype "$WS_DEFAULTS"
    rm -f "$WS_DEFAULTS"
  else
    defaults delete com.windowshade.prototype 2>/dev/null || true
  fi
  if [ -d "$ROOT/.build/demo/DemoDriver.app" ]; then
    open -W "$ROOT/.build/demo/DemoDriver.app" --args appearance "$APPEARANCE" || true
  fi
  killall Dock WindowManager 2>/dev/null || true
  [ -n "${CAFFEINATE:-}" ] && kill "$CAFFEINATE" 2>/dev/null
}
trap restore EXIT

caffeinate -dimsu &
CAFFEINATE=$!

say "开始测试（RECORD_PART=${1:-all}）"
WINDOWSHADE_LOCAL=1 WINDOWSHADE_TEST_SIGN_IDENTITY="$SIGN_ID" \
  WINDOWSHADE_TEST_KEYCHAIN="$( [ "$SIGN_ID" = "-" ] || echo "$KEYCHAIN" )" \
  RECORD_PART="${1:-all}" bash .github/demo/record.sh
status=$?

if [ "$status" = 3 ]; then
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
  cat <<MSG

权限还没给全。在“系统设置 → 隐私与安全性”里，给下面两个程序打开这三项的开关：
  辅助功能、输入监控、录屏与系统录音
    $ROOT/.build/demo/DemoDriver.app
    $ROOT/.build/demo/WindowShade.app
列表里没有的，点“＋”选上面的路径。系统问“退出并重新打开”时选“稍后”。然后再运行一次 bash run.sh。
（以上要在屏幕上操作：用另一台电脑的“屏幕共享”连到这台 Mac。）
MSG
  exit 3
fi

restore
say "打包结果"
PACK=$(mktemp -d)
mkdir -p "$PACK/results"
cp "$ROOT"/.build/demo/*.json "$ROOT"/.build/demo/*.log "$ROOT"/.build/demo/*.png \
   "$ROOT"/.build/demo/*.txt "$ROOT"/.build/demo/*.ips "$PACK/results/" 2>/dev/null || true
cp "$ROOT/KIT_VERSION" "$PACK/results/" 2>/dev/null || true
cp "$RUN_LOG" "$PACK/results/run.log"
echo "exit=$status" > "$PACK/results/exit-status.txt"
ZIP="$RESULTS/results-$STAMP.zip"
ditto -c -k "$PACK/results" "$ZIP"
rm -rf "$PACK"
printf '\n测试结束（退出码 %s）。把这个文件发给 Claude：\n  %s\n' "$status" "$ZIP"
exit "$status"
