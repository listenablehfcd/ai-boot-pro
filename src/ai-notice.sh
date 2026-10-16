#!/bin/bash
# ============================================================
# AI 给现场操作者留言的入口（供 SSH 登录后的远程 AI 使用）
#
#   ai-notice.sh "I am going to check the disk, please wait"
#
# 为什么不直接写 /dev/tty1：tty1 被救援界面占用，直接写进去会把界面画花。
# 所以这里只追加到一个文件，由监视页在最下方显示最近几条。
# ============================================================
set -u
source /usr/local/bin/ai-boot-common.sh 2>/dev/null || true

msg="${1:-}"
[ -n "$msg" ] || { echo "usage: ai-notice.sh \"message\"" >&2; exit 1; }

f="${AI_BOOT_DIR:-/run/ai-boot}/notice.txt"
mkdir -p "$(dirname "$f")" 2>/dev/null || true
printf '%s  %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '--:--:--')" "$msg" >> "$f" 2>/dev/null \
  || { echo "cannot write $f" >&2; exit 1; }

# 只保留最近 50 条，别让文件无限长大
if [ "$(wc -l < "$f" 2>/dev/null || echo 0)" -gt 50 ]; then
    tail -n 50 "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null || true
fi
echo "notice added: $msg"
