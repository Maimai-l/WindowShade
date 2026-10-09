#!/bin/bash
# 生成一个在自己的 Mac 上运行测试的测试包（不经过 GitHub）：当前提交里编译和测试要用的文件，加上根目录的 run.sh。
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
在这台 Mac 上运行 WindowShade 的全部场景测试，不经过 GitHub。

1. 用来运行测试的账户登录桌面（可以用屏幕共享），不要锁定屏幕。测试会操作真实的窗口，
   并临时修改几项系统设置，运行结束后改回；最好用一个单独的账户。
2. 在终端里：
     cd WindowShade-test-kit
     bash run.sh
3. 第一次会停在权限这一步，按提示在系统设置里打开开关，再运行一次 bash run.sh。
4. 运行结束后（约 22 分钟），终端最后一行是结果文件的路径（~/WindowShadeTests/results-….zip），把它发给 Claude。
5. 只重新运行上一次没通过的场景：bash run.sh failed；只运行指定的几条：bash run.sh A35 C03；
   只运行录像、E13 和检查的检查：bash run.sh recordings（权限场景组要改权限数据库，在本机上跳过）。

需要：Swift 6.0 或更新的命令行工具（macOS 14 上是 16.2）。有 ffmpeg 时会多做录像的逐帧检查，没有也能运行。
TXT
chmod +x "$work/$name/run.sh"
tar -C "$work" -czf "$out/$name.tar.gz" "$name"
ls -l "$out/$name.tar.gz"
