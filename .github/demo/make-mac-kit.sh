#!/bin/bash
# 打一个在自己的 Mac 上跑测试的包（不经过 GitHub）：当前提交里编译和测试要用的文件，加上根目录的 run.sh。
# 用法：bash .github/demo/make-mac-kit.sh <输出目录>   → <输出目录>/WindowShade-test-kit.tar.gz
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:?usage: make-mac-kit.sh <output directory>}"
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
name=WindowShade-test-kit
git archive --format=tar --prefix="$name/" HEAD prototype .github/demo tests assets/app-icon | tar -x -C "$work"
git log -1 --format='%h %s' > "$work/$name/KIT_VERSION"
cat > "$work/$name/run.sh" <<'SH'
#!/bin/bash
exec bash "$(dirname "$0")/.github/demo/run-on-this-mac.sh" "$@"
SH
cat > "$work/$name/说明.txt" <<'TXT'
在这台 Mac 上跑 WindowShade 的全部场景测试，不经过 GitHub。

1. 用要跑测试的账户登录桌面（可以用屏幕共享），屏幕不要锁。测试会操作真实的窗口，
   并临时改几项系统设置，跑完改回；最好用一个单独的账户。
2. 在终端里：
     cd WindowShade-test-kit
     bash run.sh
3. 第一次会停在权限这一步，按提示在系统设置里打开开关，再运行一次 bash run.sh。
4. 跑完（约一小时）终端最后一行是结果文件的路径（~/WindowShadeTests/results-….zip），把它发给 Claude。

需要：Xcode 26 或对应的命令行工具（Swift 6）。有 ffmpeg 时会多做录像的逐帧检查，没有也能跑。
TXT
chmod +x "$work/$name/run.sh"
tar -C "$work" -czf "$out/$name.tar.gz" "$name"
ls -l "$out/$name.tar.gz"
