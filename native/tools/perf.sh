#!/bin/bash
# perf.sh — 用帧耗时探针测量渲染开销 (PerfMonitor, XQ_PERF=1)。
#
# 用法:
#   bash tools/perf.sh                 # 默认跑一组对比场景
#   bash tools/perf.sh storm 8         # 只跑 XQ_FX=storm, 采样 8 秒
#   bash tools/perf.sh "rain" 5        # 自定义场景 (可写 XQ_FX 的任意取值)
#
# 背景: 探针只在 XQ_PERF=1 时启用, 正常使用零开销。
# 60fps 的预算是 16.7ms/帧 —— 用它对照实测值判断"到底谁在拖后腿"。
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="/Applications/人机中国象棋.app/Contents/MacOS/Xiangqi"

if [ ! -x "$BIN" ]; then echo "✗ 找不到 $BIN, 先跑 bash build_app.sh"; exit 2; fi

one() {                       # one <XQ_FX 取值> <秒数> [附加环境变量]
  local fx="$1" secs="$2" extra="${3:-}"
  local log="/tmp/xqperf.log"
  : > "$log"
  if [ -n "$extra" ]; then
    env XQ_PERF=1 "XQ_FX=$fx" "$extra" "$BIN" >/dev/null 2>"$log" &
  else
    env XQ_PERF=1 "XQ_FX=$fx" "$BIN" >/dev/null 2>"$log" &
  fi
  local pid=$!
  sleep "$secs"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  if ! grep -q '\[perf\]' "$log" 2>/dev/null; then
    printf '  %-22s (无样本 —— 该场景没有持续动画, 定时器会停)\n' "$(desc "$fx")"
    return
  fi
  awk -v label="$(desc "$fx")" '/\[perf\]/ {
      for (i=1;i<=NF;i++) {
        if ($i ~ /^平均/) { gsub(/ms/,"",$(i+1)); s+=$(i+1); n++; if($(i+1)>mx)mx=$(i+1) }
        if ($i ~ /^实测/) { gsub(/fps/,"",$(i+1)); f+=$(i+1); m++ }
      }
    } END {
      if (n>0) printf "  %-22s 平均 %5.2f ms/帧   最慢 %5.2f ms   %5.1f fps   (%d 个窗口)\n",
                     label, s/n, mx, f/m, n
      else printf "  %-22s (无样本)\n", label
    }' "$log"
}

desc() {                      # 把 XQ_FX 取值翻成人话
  case "$1" in
    none)      echo "空棋盘 (静止, 基准)" ;;
    crack)     echo "5 道裂痕 (静止)" ;;
    crack40)   echo "40 道裂痕 (静止, 满负荷)" ;;
    *)         echo "$1" ;;
  esac
}

if [ $# -ge 1 ]; then
  echo "单场景: XQ_FX=$1, 采样 ${2:-8}s"
  echo ""
  one "$1" "${2:-8}"
else
  echo "帧耗时扫描 (每场景 6 秒)。60fps 预算 = 16.7 ms/帧"
  echo ""
  printf '  %-22s %s\n' "场景" "实测"
  echo "  ──────────────────────────────────────────────────────────────"
  for spec in "none||" "crack|XQ_CRACKS=5|" "crack|XQ_CRACKS=40|40 道裂痕"; do
    IFS='|' read -r fx extra label <<< "$spec"
    [ -n "$label" ] || label="$fx"
    one "$fx" 6 "$extra"
  done
  echo ""
  echo "  注: 天气/演员等常驻动画已于 2026-09-25 移除; 静止场景的定时器会自动停掉,"
  echo "      这本身就是「没有空转」的证据。要走子动画的帧采样请在游戏内连续走子。"
fi
