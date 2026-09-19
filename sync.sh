#!/usr/bin/env bash
# 一键同步：暂存 -> 提交 -> 推送 -> 核对
# 用法:
#   ./sync.sh                    自动生成提交信息(时间戳)
#   ./sync.sh "修复走子动画抖动"   使用自定义提交信息
#   ./sync.sh --status           只看状态, 不做任何改动
set -uo pipefail

cd "$(dirname "$0")" || exit 1

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
say() { printf '%s\n' "$*"; }

# ---------- --status: 只读 ----------
if [ "${1:-}" = "--status" ]; then
  git status -sb
  echo
  say "${DIM}未提交改动:${RST}"
  git status --porcelain || true
  echo
  say "${DIM}本地领先远端的提交:${RST}"
  git log origin/main..HEAD --oneline 2>/dev/null || say "  (无法读取 origin/main)"
  exit 0
fi

# ---------- 前置检查 ----------
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  say "${RED}✗ 当前目录不是 git 仓库${RST}"; exit 1
fi
BRANCH=$(git branch --show-current)
if [ -z "$BRANCH" ]; then
  say "${RED}✗ 处于分离头指针状态, 请先切回分支${RST}"; exit 1
fi
if ! git remote get-url origin >/dev/null 2>&1; then
  say "${RED}✗ 未配置远程 origin${RST}"; exit 1
fi

# ---------- 1. 暂存 ----------
git add -A
if git diff --cached --quiet; then
  say "${DIM}没有需要提交的改动${RST}"
else
  # ---------- 2. 提交 ----------
  MSG="${1:-}"
  if [ -z "$MSG" ]; then
    MSG="同步 $(date '+%Y-%m-%d %H:%M')"
  fi
  CHANGED=$(git diff --cached --name-only | wc -l | tr -d ' ')
  if ! git commit -q -m "$MSG"; then
    say "${RED}✗ 提交失败${RST}"; exit 1
  fi
  say "${GRN}✓ 已提交${RST} ${DIM}(${CHANGED} 个文件)${RST}  $MSG"
fi

# ---------- 3. 推送 ----------
# 本机 github.com 的 HTTPS 被阻断, 走 SSH 443 通道; 偶发首次失败时自动重试
push_once() { git push origin "$BRANCH" 2>&1; }
OUT=$(push_once); RC=$?
if [ $RC -ne 0 ]; then
  say "${YEL}· 首次推送未成功, 重试一次...${RST}"
  sleep 2
  OUT=$(push_once); RC=$?
fi
if [ $RC -ne 0 ]; then
  say "${RED}✗ 推送失败${RST}"
  printf '%s\n' "$OUT" | sed 's/^/    /'
  say ""
  say "${DIM}排查提示: 本机 github.com:443 被阻断属正常, 应走 ssh.github.com:443 通道;"
  say "先跑 'ssh -T git@github.com' 确认认证是否仍有效。${RST}"
  exit 1
fi
printf '%s\n' "$OUT" | grep -qE 'Everything up-to-date' \
  && say "${DIM}远端已是最新, 无需推送${RST}" \
  || say "${GRN}✓ 已推送${RST} -> origin/${BRANCH}"

# ---------- 4. 核对 ----------
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git ls-remote origin "refs/heads/$BRANCH" 2>/dev/null | awk '{print $1}')
echo
if [ "$LOCAL" = "$REMOTE" ]; then
  say "${GRN}✓ 本地与远端已同步${RST}  ${DIM}${LOCAL:0:7}${RST}"
else
  say "${YEL}! 本地 ${LOCAL:0:7} 与远端 ${REMOTE:0:7} 不一致${RST}"
  exit 1
fi
say "${DIM}https://github.com/Bang-Liu-New-Era/tan-zimu-xiangqi${RST}"
