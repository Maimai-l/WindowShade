#!/bin/bash
# 生成一个在自己的 Mac 上运行测试的测试包（不经过 GitHub）：当前提交里编译和测试要用的文件，加上根目录的 run.sh。
# 用法：bash .github/demo/make-mac-kit.sh <输出目录> [要跑的部分和场景……]   → <输出目录>/WindowShade-test-kit.tar.gz
# 给了要跑的部分和场景（例如 recordings E11 B06-alone），就写进测试包的 RUN_THIS，用户只运行 bash run.sh，不用记参数。
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:?usage: make-mac-kit.sh <output directory> [parts and scenario ids]}"
shift
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
name=WindowShade-test-kit
git archive --format=tar --prefix="$name/" HEAD prototype .github/demo tests assets/app-icon | tar -x -C "$work"
git log -1 --format='%h %s' > "$work/$name/KIT_VERSION"
if [ $# -gt 0 ]; then
  echo "$*" > "$work/$name/RUN_THIS"
  # 说明里用中文名称，不给用户看参数名。
  names=$(echo "$*" | sed -e 's/recordings/录像检查/' -e 's/random/随机操作/' -e 's/ /、/g')
  scope="这个测试包只运行以下几项：${names}"
else
  scope="这个测试包运行全部场景，约 22 分钟"
fi
cat > "$work/$name/run.sh" <<'SH'
#!/bin/bash
exec bash "$(dirname "$0")/.github/demo/run-on-this-mac.sh" "$@"
SH
cat > "$work/$name/说明.txt" <<TXT
在这台 Mac 上运行 WindowShade 的场景测试，不经过 GitHub。${scope}。

1. 用来运行测试的账户登录桌面（可以用屏幕共享），不要锁定屏幕。测试会操作真实的窗口，
   并临时修改几项系统设置，运行结束后改回；最好用一个单独的账户。
2. 在终端里：
     cd WindowShade-test-kit
     bash run.sh
3. 第一次会停在权限这一步，按提示在系统设置里打开开关，再运行一次 bash run.sh。
4. 运行结束后，终端最后一行是结果文件的路径（~/WindowShadeTests/results-….zip），把它发给 Claude。
5. 只重新运行上一次没通过的场景：bash run.sh failed。
TXT
cat >> "$work/$name/说明.txt" <<'TXT'

需要：Swift 6.0 或更新的命令行工具（macOS 14 上是 16.2）。有 ffmpeg 时会多做录像的逐帧检查，没有也能运行。
TXT
chmod +x "$work/$name/run.sh"
tar -C "$work" -czf "$out/$name.tar.gz" "$name"
ls -l "$out/$name.tar.gz"
