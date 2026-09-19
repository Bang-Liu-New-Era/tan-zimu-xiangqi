#!/bin/bash
# repair_launchservices.sh — 修复「双击人机中国象棋.app 没反应」
#
# 症状: 进程其实在后台活着(或已消失), 但双击 App 什么都不发生。
# 根因: 同一个 bundle id (com.example.xiangqi) 在 LaunchServices 里注册了多份,
#       其中一些指向已被丢进废纸篓的旧副本 —— 双击时系统激活的是那份僵尸,
#       而它没有可见窗口, 于是"看起来没反应"。
#
# 本脚本: 结束残留进程 → 注销所有失效/废弃路径 → 重新注册 /Applications 正式版。
set -u

APP_NAME="人机中国象棋"
BID="com.example.xiangqi"
APP="/Applications/${APP_NAME}.app"
EXE="Xiangqi"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "== 1. 结束残留进程 =="
if pkill -f "Contents/MacOS/${EXE}" 2>/dev/null; then
  sleep 1; echo "  已结束残留实例"
else
  echo "  (没有残留实例)"
fi

echo "== 2. 收集该 App 的所有注册路径 =="
# 第一步就按名字过滤, 避免误伤其它 App 的注册项
STALE=$(mktemp)
"$LSREG" -dump 2>/dev/null \
  | grep -E "^path:" \
  | sed 's/^path:[[:space:]]*//; s/[[:space:]]*(0x[0-9a-f]*)$//' \
  | grep -F "${APP_NAME}" \
  | sort -u \
  | while IFS= read -r p; do
      case "$p" in
        *"/.Trash/"*|/tmp/*|/private/tmp/*|/var/folders/*) echo "$p" ;;   # 废纸篓/临时目录里的副本
        *) [ -e "$p" ] || echo "$p" ;;                                    # 文件已不存在的失效注册
      esac
    done > "$STALE"

COUNT=$(grep -c . "$STALE" 2>/dev/null || echo 0)
echo "  发现 $COUNT 条失效/废弃注册"
while IFS= read -r p; do
  [ -z "$p" ] && continue
  "$LSREG" -u "$p" 2>/dev/null && echo "  已注销: $p"
done < "$STALE"
rm -f "$STALE"

echo "== 3. 重新注册正式版 =="
if [ -d "$APP" ]; then
  "$LSREG" -f "$APP" 2>/dev/null && echo "  已注册: $APP"
else
  echo "  ！$APP 不存在, 请先运行 native/build_app.sh"
fi

echo "== 4. 校验 =="
REMAIN=$("$LSREG" -dump 2>/dev/null | grep -E "^path:" \
  | sed 's/^path:[[:space:]]*//; s/[[:space:]]*(0x[0-9a-f]*)$//' \
  | grep -c "${APP_NAME}" || true)
echo "  当前仍与「${APP_NAME}」相关的注册条目: $REMAIN 条 (含 /Applications 正式版)"
echo
echo "完成。现在双击 /Applications/${APP_NAME}.app 应该能正常打开。"
echo "提示: 废纸篓里的旧版本副本可以放心清空 —— 它们正是导致双击失效的僵尸注册源。"
