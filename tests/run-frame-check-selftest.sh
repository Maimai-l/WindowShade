#!/bin/bash
# 检查的检查 K05（docs/test-catalog.md 第 12 节）：录像逐帧检查（check_frames.py，I7）对错误的录像要报错。
# 用 ffmpeg 合成三段录像：正常的收起、展开；收起中途有一帧空白；以及日志里窗口回来的位置不对。
# 第一段必须通过，后两段必须报出对应的错误。需要 python3 和 ffmpeg。
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/frame-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# 窗口在 (100,100) 600x400，屏幕 800x600，1 倍。0–3.4 秒标题栏灰、正文白；3.4–6.4 秒收起：标题栏深、正文黑；之后展开。
# 收起的双击在 3.0 秒，展开的双击在 6.0 秒。
cat > "$WORK/events.json" <<'JSON'
{"window": {"x": 100, "y": 100, "w": 600, "h": 400}, "scale": 1, "screen": {"w": 800, "h": 600}, "fold": 3.0, "unfold": 6.0}
JSON
STATES="drawbox=x=100:y=100:w=600:h=400:color=0x505050:t=fill,\
drawbox=x=180:y=103:w=510:h=20:color=0x808080:t=fill:enable='lt(t,3.4)+gte(t,6.4)',\
drawbox=x=180:y=103:w=510:h=20:color=0x3c3c3c:t=fill:enable='between(t,3.4,6.4)',\
drawbox=x=140:y=170:w=300:h=60:color=0xf0f0f0:t=fill:enable='lt(t,3.4)+gte(t,6.4)',\
drawbox=x=140:y=170:w=300:h=60:color=0x101010:t=fill:enable='between(t,3.4,6.4)'"
make_video() {
  local out="$1" extra="$2"
  ffmpeg -v error -y -f lavfi -i "color=c=0x202020:s=800x600:r=10:d=9.5" \
    -vf "$STATES$extra" -c:v ffv1 "$out"
}
make_video "$WORK/clean.mkv" ""
# 3.6 秒那一帧整屏白：收起过程中的空帧。
make_video "$WORK/blank.mkv" ",drawbox=x=0:y=0:w=800:h=600:color=0xffffff:t=fill:enable='between(t,3.55,3.65)'"

echo "geometry: restore immediate target=(100,100 600x400) ok=(size:true,pos:true) actual=(100,100 600x400) id=1" > "$WORK/good.log"
echo "geometry: restore immediate target=(100,100 600x400) ok=(size:true,pos:true) actual=(140,100 600x400) id=1" > "$WORK/moved.log"

failures=0
expect() {
  local name="$1" want="$2" pattern="$3"; shift 3
  local out status=0
  out="$(python3 .github/demo/check_frames.py "$@" 2>&1)" || status=$?
  if [ "$want" = pass ] && [ "$status" -eq 0 ]; then
    echo "ok   $name: passes"
  elif [ "$want" = fail ] && [ "$status" -ne 0 ] && grep -q "$pattern" <<<"$out"; then
    echo "ok   $name: reports \"$pattern\""
  else
    echo "FAIL $name: expected $want${pattern:+ with \"$pattern\"}, exit $status"
    echo "$out" | sed 's/^/     /'
    failures=$((failures + 1))
  fi
}
# 拖动卷帘条（第 6.5 节）：收起 3.4–9.4 秒，标题栏上三块浅色方块代表卷帘条上的内容；5.6–6.1 秒指针匀速
# 往右 120 点，6.1–6.6 秒拖回，深色条和上面的方块一起移动。卷帘条跟手、落后 0.15 秒、中途停 0.15 秒三种录像。
python3 - "$WORK/drag-events.json" <<'PY'
import json, sys
def dx(t):
    if 5.6 <= t < 6.1: return 240 * (t - 5.6)
    if 6.1 <= t < 6.6: return 120 - 240 * (t - 6.1)
    return 0
path, t = [], 5.6
while t <= 6.6:
    path.append([round(t, 4), 400 + dx(t), 112]); t += 1 / 120
json.dump({"window": {"x": 100, "y": 100, "w": 600, "h": 400}, "scale": 1, "screen": {"w": 800, "h": 600},
           "fold": 3.0, "unfold": 9.0, "drag": {"grab": [400, 112], "path": path}}, open(sys.argv[1], "w"))
PY
make_drag_video() {
  local out="$1" shift_expr="$2"
  local dx="if(between(T,5.6,6.1),240*(T-5.6),if(between(T,6.1,6.6),120-240*(T-6.1),0))"
  dx="${dx//T/$shift_expr}"
  # drawbox 的位置不逐帧重算：卷帘条单独画好，用 overlay 按时间移动。
  ffmpeg -v error -y -f lavfi -i "color=c=0x202020:s=800x600:r=30:d=12.5" \
    -f lavfi -i "color=c=0x3c3c3c:s=510x20:r=30:d=12.5" -filter_complex "\
[1]drawbox=x=20:y=0:w=40:h=20:color=0xc0c0c0:t=fill,\
drawbox=x=140:y=0:w=60:h=20:color=0xe0e0e0:t=fill,\
drawbox=x=300:y=0:w=30:h=20:color=0xa0a0a0:t=fill[strip];\
[0]drawbox=x=100:y=100:w=600:h=400:color=0x505050:t=fill,\
drawbox=x=180:y=103:w=510:h=20:color=0x808080:t=fill:enable='lt(t,3.4)+gte(t,9.4)',\
drawbox=x=140:y=170:w=300:h=60:color=0xf0f0f0:t=fill:enable='lt(t,3.4)+gte(t,9.4)',\
drawbox=x=140:y=170:w=300:h=60:color=0x101010:t=fill:enable='between(t,3.4,9.4)'[base];\
[base][strip]overlay=x='180+$dx':y=103:enable='between(t,3.4,9.4)'" -c:v ffv1 "$out"
}
make_drag_video "$WORK/drag-smooth.mkv" "t"
make_drag_video "$WORK/drag-lag.mkv" "(t-0.15)"
make_drag_video "$WORK/drag-stall.mkv" "if(between(t,5.7,5.85),5.7,t)"

expect "clean recording" pass "" "$WORK/clean.mkv" "$WORK/events.json" "$WORK/good.log"
expect "blank frame while folding" fail "blank or covered" "$WORK/blank.mkv" "$WORK/events.json" "$WORK/good.log"
expect "window back in the wrong place" fail "came back at" "$WORK/clean.mkv" "$WORK/events.json" "$WORK/moved.log"
export WINDOWSHADE_LOCAL=1   # 拖动的判定只在真机上生效
expect "strip follows the drag" pass "" "$WORK/drag-smooth.mkv" "$WORK/drag-events.json" "$WORK/good.log"
expect "strip trails the drag" fail "trailed the pointer" "$WORK/drag-lag.mkv" "$WORK/drag-events.json" "$WORK/good.log"
expect "strip stalls during the drag" fail "stopped while the pointer moved" "$WORK/drag-stall.mkv" "$WORK/drag-events.json" "$WORK/good.log"

if [ "$failures" -eq 0 ]; then
  echo "PASS: check_frames.py passes correct recordings and reports a blank frame, a misplaced window, and a strip that trails or stalls while dragged"
else
  echo "FAILED $failures"
  exit 1
fi
