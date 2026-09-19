#!/bin/bash
# regress.sh — 渲染回归快照: 逐场景离屏出图, 与基线逐像素比对。
#
# 用法:
#   bash tools/regress.sh shoot   <目录>              把当前 App 的全部场景出图到 <目录>
#   bash tools/regress.sh compare <基线目录> <新目录>  出图到 <新目录> 并与 <基线目录> 比对
#
# 场景分两类:
#   [strict] clear / paths / crack —— 无随机数、无动画推进, 必须逐像素相同(容差 0)。
#            这几个场景是「行为未变」的硬证据。
#   [loose]  crackmid / rain / storm / horse —— 依赖快照瞬间的精确时刻(裂痕生长进度、
#            雨滴相位、马的位置), 两次运行本就不同, 只做容差比对。
#
#   crackmid 为何不是 strict (2026-09-19 实测):
#     「裂痕生长中」场景的可见长度 = (快照时刻 - 裂纹出生时刻) / 生长时长,
#     而这两者都由 `DispatchQueue.main.asyncAfter` 调度, 有毫秒级抖动。
#     同一份二进制连出 3 张, 两两差异 0.35%~0.69% (最大通道差 26~46);
#     而「重构前 vs 重构后」的差异是 0.69% (Δ50) —— 落在固有抖动区间内,
#     因此它不能作为回归判据。真正证明裂痕渲染未变的是 strict 的 crack(成熟态)。
set -uo pipefail
cd "$(dirname "$0")/.."
NATIVE="$PWD"
BIN="/Applications/人机中国象棋.app/Contents/MacOS/Xiangqi"

# 名称|环境变量|严格性
SCENES=(
  "clear|XQ_FX=none|strict"
  "paths|XQ_FX=paths|strict"
  "crack|XQ_FX=crack|strict"
  "crackmid|XQ_FX=crack,crack_mid|loose"
  "rain|XQ_FX=rain|loose"
  "storm|XQ_FX=crack,storm|loose"
  "horse|XQ_FX=crack,horse|loose"
)

shoot() {                       # shoot <输出路径> <env...>
  local out="$1"; shift
  rm -f "$out"
  env "$@" "XQ_SNAPSHOT=$out" XQ_SNAP_DELAY=1.2 "$BIN" >/dev/null 2>&1 &
  local pid=$!
  local waited=0
  while [ ! -f "$out" ] && [ $waited -lt 100 ]; do sleep 0.2; waited=$((waited+1)); done
  sleep 0.2
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ -f "$out" ]
}

capture() {                     # capture <目录> -> 回显失败数
  local dir="$1"; mkdir -p "$dir"
  local bad=0
  echo "==== 出图 -> $dir ===="
  for row in "${SCENES[@]}"; do
    IFS='|' read -r name env kind <<< "$row"
    if shoot "$dir/$name.png" $env; then
      printf '  OK   %-9s %8s bytes\n' "$name" "$(stat -f%z "$dir/$name.png")"
    else
      printf '  FAIL %-9s 未生成\n' "$name"; bad=$((bad+1))
    fi
  done
  return $bad
}

if [ ! -x "$BIN" ]; then
  echo "✗ 找不到已安装的 App: $BIN"; echo "  先跑 bash build_app.sh"; exit 2
fi

MODE="${1:-compare}"

if [ "$MODE" = "shoot" ]; then
  DIR="${2:-/tmp/xqshot}"
  capture "$DIR" || exit 1
  echo ""; echo "✓ 场景已出图到 $DIR"; exit 0
fi

# ---- compare ----
BASE="${2:-/tmp/xqbase}"
NEW="${3:-/tmp/xqnew}"
[ -d "$BASE" ] || { echo "✗ 基线目录不存在: $BASE"; echo "  先跑: bash tools/regress.sh shoot $BASE"; exit 2; }

capture "$NEW" || true

echo ""
echo "==== 与基线比对 ($BASE) ===="
DIFF=0
for row in "${SCENES[@]}"; do
  IFS='|' read -r name env kind <<< "$row"
  b="$BASE/$name.png"; n="$NEW/$name.png"
  if [ ! -f "$b" ] || [ ! -f "$n" ]; then echo "  ✗ $name 缺少文件"; DIFF=$((DIFF+1)); continue; fi
  if [ "$kind" = "strict" ]; then
    out=$(swift "$NATIVE/tools/pxdiff.swift" "$b" "$n" 2>&1)
  else
    out=$(swift "$NATIVE/tools/pxdiff.swift" "$b" "$n" --tolerance 24 2>&1)
  fi
  if printf '%s' "$out" | grep -q '^✓'; then
    printf '  ✓ %-9s 逐像素完全一致\n' "$name"
  elif [ "$kind" = "loose" ]; then
    pct=$(printf '%s' "$out" | sed -n 's/.*(\(.*\)%).*/\1/p')
    if [ -n "$pct" ] && awk "BEGIN{exit !($pct < 12)}"; then
      printf '  ~ %-9s 动态场景, 差异 %s%% (容差内, 仅表示"仍在正常渲染")\n' "$name" "$pct"
    else
      printf '  ✗ %-9s 差异过大 %s%%\n' "$name" "${pct:-?}"; printf '%s\n' "$out" | sed 's/^/      /'; DIFF=$((DIFF+1))
    fi
  else
    printf '  ✗ %-9s 逐像素不一致 (行为已改变!)\n' "$name"
    printf '%s\n' "$out" | sed 's/^/      /'
    DIFF=$((DIFF+1))
  fi
done

echo ""
if [ $DIFF -eq 0 ]; then
  echo "✓✓ 回归通过: 3 个确定场景逐像素一致, 4 个动态场景在容差内"
  exit 0
else
  echo "✗✗ 回归未通过: $DIFF 个场景异常"
  exit 1
fi
