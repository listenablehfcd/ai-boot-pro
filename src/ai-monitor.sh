#!/bin/bash
# AI Boot Pro —— 救援启动盘系统
# Copyright (c) 2026 sxzxdpy  <https://github.com/listenablehfcd>
# SPDX-License-Identifier: MIT
# ============================================================
# AI-Boot 5.2 监视页
#   操作者停留在这里看着远程 AI 干活。
#   - 页面每 5 秒自动刷新，**不需要按键**（急救模式可能没有键盘）
#   - 显示连接信息（IP/端口/用户/密码/命令），方便拍照转述
#   - C  = 以 root 进入命令行（所有监视页都提供）
#   - 0  = 清除急停标记（急停后要能恢复，否则界面像坏了）
#   - E  = 急停（写 ai_estop_file + 断会话 + 停 sshd）
#   - ESC/X = 返回上一级
# ============================================================
set -u
source /usr/local/bin/ai-boot-common.sh
# 监视页要显示 SSH 密码；read_pass_file 定义在 ai-password.sh 里，
# 不 source 它就会出现 "read_pass_file: command not found"。
source /usr/local/bin/ai-password.sh

PAUSE_FILE="/root/.ai-pause"

# ai_user_name() 已移到 ai-boot-common.sh，避免和 ai-password.sh 各写一份导致行为不一致。

local_ip() {
    ip -4 -o addr show scope global 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | head -n1
}

ssh_running() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -q ":$(cfg_get ssh_port) " && return 0
    fi
    command -v pgrep >/dev/null 2>&1 && pgrep -x sshd >/dev/null 2>&1 && return 0
    return 1
}

ai_online() {
    # 版本无关：有已建连接 或 有登录会话，即视为在线。
    # （不能用 pgrep -f "sshd: $user"：OpenSSH >= 9.8 的进程名是 sshd-session）
    [ "$(ai_ssh_conn_count 2>/dev/null || echo 0)" -gt 0 ] && return 0
    [ -n "$(ai_sessions 2>/dev/null || true)" ] && return 0
    return 1
}

show_monitor_page() {
    local u ip port line found=0
    u="$(ai_user_name)"
    ip="$(local_ip)"; [ -n "$ip" ] || ip="-"
    port="$(cfg_get ssh_port)"; [ -n "$port" ] || port=22

    clear
    ui_title "$(t mon_title)"
    ui_blank
    # 连接信息放最上面：这一页最常被拍照发给远程的人/AI
    ui_line "$(t ssh_ip)    : $ip"
    ui_line "$(t ssh_port)  : $port"
    ui_line "$(t ssh_user)  : $u"
    if ssh_running; then
        ui_line "$(t mon_ssh_state)$(t mon_ssh_up)"
    else
        ui_line "$(t mon_ssh_state)$(t mon_ssh_down)"
    fi
    if ai_online; then
        ui_line "$(t mon_ai_online)$(t mon_ai_yes)"
    else
        ui_line "$(t mon_ai_online)$(t mon_ai_no)"
    fi
    ui_line "$(t ssh_pw)    : ${CURRENT_SSH_PASSWORD:-$(read_pass_file || echo "-")}"
    ui_rule
    ui_line "$(t mon_sessions)"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        ui_line "  $line"
        found=1
    done < <(ai_sessions 2>/dev/null || true)
    [ "$found" = "0" ] && ui_line "$(t mon_none)"
    ui_blank
    ui_line "$(t mon_pause)$([ -f "$PAUSE_FILE" ] && echo "$(t mon_paused)" || echo "$(t mon_notpaused)")"
    ui_line "$(t mon_stop)$([ -f "$(cfg_get ai_estop_file)" ] && echo "$(t mon_stopped)" || echo "$(t mon_notstopped)")"
    ui_line "$(t mon_donefile)$([ -f "$(cfg_get ai_done_file)" ] && echo "$(t tools_exist)" || echo "$(t tools_absent)")"
    # AI 通过 ai-notice.sh 留的话：让现场操作者不用看 SSH 也能知道 AI 在干什么
    local nf="$AI_BOOT_DIR/notice.txt"
    if [ -s "$nf" ]; then
        ui_rule
        ui_line "$(t mon_notice)"
        tail -n 3 "$nf" 2>/dev/null | while IFS= read -r line; do ui_line "  $line"; done
    fi
    ui_blank
    ui_rule
    ui_line "$(t mon_nav1)"
    ui_line "$(t mon_nav2)"
    ui_line "$(t mon_rootshell)"
    ui_line "$(t mon_clear)"
    ui_nav
}

# 急停必须真的拦得住 AI。4.1 的 E 只 touch 了一个**没人读**的 /root/.ai-stop，
# 而全系统真正被读的停止标记是配置里的那个 —— 所以按了等于没按：
# sshd 还在监听，AI 下一秒就重连。
emergency_stop() {
    local marker
    marker="$(cfg_get ai_estop_file)"
    [ -n "$marker" ] || marker="/root/.ai-estop"
    printf '1\n' > "$marker" 2>/dev/null || touch "$marker" 2>/dev/null || true
    kill_ai_session
    # 关掉 sshd，否则重连绕过急停
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop ssh 2>/dev/null || systemctl stop sshd 2>/dev/null || true
    fi
    ai_kill_sessions >/dev/null 2>&1 || true
    log "EMERGENCY STOP: sessions killed, ssh stopped, marker=$marker"
    return 0
}

# 清除急停标记 —— 没有这个入口的话，按过一次 E 之后急救就永远被跳过，
# 用户只会觉得"界面坏了"（审计里列为高危）。
clear_estop() {
    local marker
    marker="$(cfg_get ai_estop_file)"
    rm -f "$marker" 2>/dev/null || true
    log "E-stop marker cleared by operator"
    echo "$(t mon_clear_done)"
}

kill_ai_session() {
    local u pids
    u="$(ai_user_name)"
    pids="$(ai_kill_sessions 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        kill $pids 2>/dev/null || true
        echo "$(t mon_killed_a)$(echo "$pids" | wc -w)$(t mon_killed_b)"
    else
        echo "$(t mon_nosession)"
    fi
}

pause_ai() {
    local u pids
    u="$(ai_user_name)"
    touch "$PAUSE_FILE" 2>/dev/null || true
    if command -v pgrep >/dev/null 2>&1; then
        pids="$(pgrep -u "$u" 2>/dev/null || true)"
        [ -n "$pids" ] && kill -STOP $pids 2>/dev/null || true
    fi
    # 只 STOP 现有进程挡不住新会话：暂停必须同时关掉登录入口
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop ssh 2>/dev/null || systemctl stop sshd 2>/dev/null || true
    fi
    echo "$(t mon_paused_done)"
}

resume_ai() {
    local u pids
    u="$(ai_user_name)"
    rm -f "$PAUSE_FILE" 2>/dev/null || true
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null || true
    fi
    if command -v pgrep >/dev/null 2>&1; then
        pids="$(pgrep -u "$u" 2>/dev/null || true)"
        [ -n "$pids" ] && kill -CONT $pids 2>/dev/null || true
    fi
    echo "$(t mon_resumed)"
}

view_log() {
    clear
    ui_title "$(t mon_log_title)$LOG_FILE"
    if [ -f "$LOG_FILE" ]; then
        tail -n 60 "$LOG_FILE" 2>/dev/null || echo "$(t mon_read_fail)"
    else
        ui_line "$(t mon_log_missing)"
    fi
    ui_rule
    press_any_key "$(t press_any)" || return 0
}

run_monitor() {
    local c
    while true; do
        show_monitor_page
        printf '> '
        # 带超时：没人按键时每 5 秒重画一次，状态自动更新（急救模式可能没有键盘）
        c="$(read_choice 0 5 1)"
        case "$c" in
            ESC|CH:X|CH:x)
                return 0 ;;
            CH:K|CH:k)
                kill_ai_session; press_any_key "$(t press_any)" || return 0 ;;
            CH:P|CH:p)
                pause_ai; press_any_key "$(t press_any)" || return 0 ;;
            CH:R|CH:r)
                resume_ai; press_any_key "$(t press_any)" || return 0 ;;
            CH:L|CH:l)
                view_log ;;
            CH:E|CH:e)
                if confirm "$(t mon_confirm_stop)"; then
                    emergency_stop
                    echo "$(t mon_stopped_done)"
                    press_any_key "$(t press_any)" || return 0
                fi
                ;;
            CH:C|CH:c)
                # 所有监视页都能以 root 进命令行；exit 回来继续监视
                clear
                ui_title "$(t mon_shell_title)"
                ui_line "$(t mon_shell_hint)"
                ui_rule
                /bin/bash -l || true
                press_any_key "$(t press_any)" || return 0
                ;;
            NUM:0|CH:0)
                if [ -f "$(cfg_get ai_estop_file)" ]; then
                    if confirm "$(t mon_clear_confirm)"; then
                        clear_estop
                        press_any_key "$(t press_any)" || return 0
                    fi
                else
                    echo "$(t mon_clear_none)"
                    sleep 1
                fi
                ;;
            *)
                : ;;
        esac
    done
}

# 只在被直接执行时跑；被 source 时不要抢屏幕（审计：缺 BASH_SOURCE 守卫）
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_monitor
fi
