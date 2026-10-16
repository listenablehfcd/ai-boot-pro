#!/bin/bash
# AI Boot Pro —— 救援启动盘系统
# Copyright (c) 2026 sxzxdpy  <https://github.com/listenablehfcd>
# SPDX-License-Identifier: MIT
# ============================================================
# AI-Boot 5.2 急救模式
#
# 与"引导性配置"的分工（本版最重要的设计边界）：
#   引导性配置（主菜单 A/B/E/F/G）：用户**键鼠正常**时使用，用来提前把 U 盘配置写好。
#   急救模式（主菜单 3 / 30 秒倒计时自动进）：最后一环。用户**可能完全无法操作**，
#     只有一块屏幕。所以它必须做到"尽量不用按键也能一路走完"。
#
# 流程：
#   第 0 页：你能操作键盘吗？  1 能   2 不能/只有屏幕
#           —— 20 秒无人操作自动按「2」继续
#     ├─ 能   → 引导式：问一句"你能提供哪种网络"，按选择执行
#     └─ 不能 → 全自动：①U盘配置 ②有线 ③上次成功的 WiFi
#                        ④手机热点 ⑤本机热点 ⑥本地指引页
#   任一成功 → 常驻信息页（IP/端口/用户/密码/命令）→ 监视页
#
# 5.0 修掉的急救缺陷（审计逐条证实）：
#   - 用户按 ESC 中止时返回 2（原来返回 1，会继续跑到最后把 root shell 塞给用户）
#   - "跳过"与"成功"分开（原来 hotspot_enabled=0 会让兜底步骤永远不执行）
#   - 每一步都可中止、都有超时、都显示"在做什么/结果/下一步"
#   - 起 sshd 后真的检查是否在监听，失败说清楚
#   - 手机热点改成"扫描 → 选你的手机 → 输密码"，不再要求用户把手机热点改名
#   - 连上后不等按键，自动进监视页（现场可能没有键盘）
# ============================================================
set -u
source /usr/local/bin/ai-boot-common.sh
source /usr/local/bin/ai-network.sh
source /usr/local/bin/ai-password.sh
source /usr/local/bin/ai-ssh.sh

# 人工急停：只有操作者在监视页按 E 才会设置
ai_stopped() { [ -f "$(cfg_get ai_estop_file)" ]; }
# AI 完工：AI 自己 touch 的标记（见 AI-README 第 4 节）
ai_done()    { [ -f "$(cfg_get ai_done_file)" ]; }

LAST_WIFI_FILE=""
last_wifi_file() {
    [ -n "$LAST_WIFI_FILE" ] || LAST_WIFI_FILE="$AI_BOOT_DIR/last_wifi"
    printf '%s' "$LAST_WIFI_FILE"
}
# 记住连成功的那一个，下次急救（③）优先试它
remember_wifi() {
    printf '%s\n%s\n' "$1" "$2" > "$(last_wifi_file)" 2>/dev/null || true
}
last_wifi_ssid() { sed -n '1p' "$(last_wifi_file)" 2>/dev/null; }
last_wifi_pass() { sed -n '2p' "$(last_wifi_file)" 2>/dev/null; }

# ------------------------------------------------------------
# 起 SSH 并进入常驻监视页
# ------------------------------------------------------------
rescue_bring_up_ssh() {
    prepare_ssh_password auto
    # 5.0 重写时这里留了个已删除的函数名（start_ssh_service_quiet），
    # 导致急救走到这一步必然 "command not found"、sshd 永远起不来。
    command -v start_ssh_service_quiet >/dev/null 2>&1         && start_ssh_service_quiet         || start_ssh_service
    sleep 2
    clear
    if command -v ssh_listening >/dev/null 2>&1 && ! ssh_listening; then
        # 起不来就要说清楚，别让操作者对着一个永远连不上的地址等
        ui_title "$(t rescue_ssh_fail_title)"
        ui_line "$(t rescue_ssh_fail_l1)$(cfg_get ssh_port)"
        command -v sshd_diagnose >/dev/null 2>&1 && ui_line "$(sshd_diagnose)"
        ui_line "$(t rescue_ssh_fail_l2)"
        ui_rule
    else
        # 光给密码不够：还要告诉操作者 AI 该连到哪里（IP/端口/用户/命令）
        command -v show_connection_card >/dev/null 2>&1 && show_connection_card
    fi
    # 现场可能没有键盘：这里不能阻塞等按键
    ui_wait_key 8 "$(t rescue_auto_monitor)"
    /usr/local/bin/ai-monitor.sh
}

# ------------------------------------------------------------
# 每一屏都告诉用户：在做什么 / 结果 / 下一步（全自动路径不需要按键）
# ------------------------------------------------------------
auto_screen() {
    local step="$1" title="$2" detail="${3:-}"
    clear
    ui_title "$(t rescue_title)"
    ui_line "$(t rescue_auto_mode)"
    ui_rule
    ui_line "$(printf '%s %s' "$step" "$title")"
    if [ -n "$detail" ]; then
        ui_rule
        ui_line "$detail"
    fi
    ui_rule
    ui_line "$(t rescue_auto_hint)"
}

# ------------------------------------------------------------
# 第 0 页：你能操作键盘吗？（20 秒自动选"不能"）
# 返回 0 = 能操作（引导式）；1 = 不能/没响应（全自动）
# ------------------------------------------------------------
rescue_ask_can_type() {
    # 只画一次，之后**只更新倒计时那一行**：原来每秒 clear+整屏重画，屏幕在闪。
    local i=0 c
    clear
    ui_title "$(t rescue_title)"
    ui_line "$(t rescue_intro1)"
    ui_line "$(t rescue_esc_hint)"
    ui_rule
    ui_line "$(t rescue_can_type)"
    ui_line "$(t rescue_can_yes)"
    ui_line "$(t rescue_can_no)"
    ui_rule
    while [ "$i" -lt 20 ]; do
        printf '\r%s %2d s ' "$(t rescue_auto_pick_no)" "$((20 - i))"
        c="$(read_choice 2 1 1)"
        case "$c" in
            NUM:1|CH:1) printf '\n'; return 0 ;;
            NUM:2|CH:2) printf '\n'; return 1 ;;
            ESC|CH:X|CH:x) printf '\n'; return 2 ;;   # 放弃急救、回主菜单
            TIMEOUT|'') : ;;
            *) printf '\n'; return 0 ;;   # 能按键本身就说明他能操作
        esac
        i=$((i + 1))
    done
    printf '\n'
    return 1
}

# ------------------------------------------------------------
# 全自动六步
# ------------------------------------------------------------
auto_step_config() {
    auto_screen "$(t rescue_step1)" "$(t rescue_s1_title)" "$(t rescue_s1_trying)"
    if ! cfg_is_on auto_config; then
        auto_screen "$(t rescue_step1)" "$(t rescue_s1_title)" "$(t rescue_s1_skip_auto)"
        sleep 3
        return 1
    fi
    if cfg_is_on wifi_auto_connect && [ -n "$(cfg_get wifi_ssid)" ]; then
        auto_screen "$(t rescue_step1)" "$(t rescue_s1_title)" "$(t rescue_s1_try_wifi)$(cfg_get wifi_ssid)"
        wifi_connect "$(cfg_get wifi_ssid)" "$(cfg_get wifi_password)" || true
        if wait_online 30; then
            remember_wifi "$(cfg_get wifi_ssid)" "$(cfg_get wifi_password)"
            rescue_bring_up_ssh
            return 0
        fi
    fi
    if cfg_is_on wired_dhcp || [ -n "$(cfg_get static_ip)" ]; then
        auto_screen "$(t rescue_step1)" "$(t rescue_s1_title)" "$(t rescue_s1_wired_try)"
        if net_up_wired_dhcp; then
            rescue_bring_up_ssh
            return 0
        fi
    fi
    return 1
}

auto_step_wired() {
    auto_screen "$(t rescue_step2)" "$(t rescue_wired_title)" "$(t rescue_wired_trying)"
    if net_up_wired_dhcp && wait_online 20; then
        rescue_bring_up_ssh
        return 0
    fi
    auto_screen "$(t rescue_step2)" "$(t rescue_wired_title)" "$(t rescue_wired_fail)"
    sleep 3
    return 1
}

auto_step_last_wifi() {
    local ssid pass
    ssid="$(last_wifi_ssid)"; pass="$(last_wifi_pass)"
    [ -n "$ssid" ] || return 1
    auto_screen "$(t rescue_step3)" "$(t rescue_lastwifi_title)" "$(t rescue_try_connect)$ssid"
    if wifi_connect "$ssid" "$pass" && wait_online 30; then
        rescue_bring_up_ssh
        return 0
    fi
    auto_screen "$(t rescue_step3)" "$(t rescue_lastwifi_title)" "$(t rescue_lastwifi_fail)"
    sleep 3
    return 1
}

# 手机热点：全自动时只能用配置里预先写好的；没写就跳过（现场没人能输入）
auto_step_phone_hotspot() {
    local ssid pass
    ssid="$(cfg_get phone_hotspot_ssid)"
    pass="$(cfg_get phone_hotspot_password)"
    [ -n "$ssid" ] || return 1
    auto_screen "$(t rescue_step4)" "$(t rescue_s2_title)" "$(t rescue_try_connect)$ssid"
    if wifi_connect "$ssid" "$pass" && wait_online 30; then
        remember_wifi "$ssid" "$pass"
        rescue_bring_up_ssh
        return 0
    fi
    auto_screen "$(t rescue_step4)" "$(t rescue_s2_title)" "$(t rescue_s2_fail_auto)"
    sleep 3
    return 1
}

auto_step_pc_hotspot() {
    local ssid pass
    cfg_is_on hotspot_enabled || return 1
    ssid="$(hotspot_ssid)"; pass="$(hotspot_pass)"
    auto_screen "$(t rescue_step5)" "$(t rescue_s3_title)" "$(t rescue_s3_starting)"
    if start_pc_hotspot "$ssid" "$pass"; then
        clear
        ui_title "$(t rescue_s3_started)"
        ui_line "$(t rescue_ssid_label)$ssid"
        ui_line "$(t rescue_pass_label)$pass"
        ui_rule
        ui_line "$(t rescue_s3_join_hint)"
        sleep 4
        rescue_bring_up_ssh
        return 0
    fi
    auto_screen "$(t rescue_step5)" "$(t rescue_s3_title)" "$(t rescue_s3_fail)"
    sleep 3
    return 1
}

# 全部失败：给"本地指引页"，**不把用户丢进 shell**（按 5 并确认才进）
rescue_guide_page() {
    clear
    ui_title "$(t rescue_s4_title)"
    ui_line "$(t rescue_s4_line1)"
    ui_line "$(t rescue_s4_line2)"
    ui_rule
    ui_line "$(t rescue_s4_manual)"
    ui_line "$(t rescue_s4_keys)"
    ui_rule
    press_any_key "$(t press_any)" || return 0
    if confirm "$(t rescue_s4_shell_confirm)"; then
        /usr/local/bin/ai-shell.sh
    fi
    return 0
}

rescue_auto() {
    if [ ! -f "$CONFIG_FILE" ]; then
        auto_screen "$(t rescue_step1)" "$(t rescue_no_config)" ""
        sleep 3
    fi
    auto_step_config   && return 0
    ai_stopped && return 0
    auto_step_wired    && return 0
    ai_stopped && return 0
    auto_step_last_wifi && return 0
    ai_stopped && return 0
    auto_step_phone_hotspot && return 0
    ai_stopped && return 0
    auto_step_pc_hotspot && return 0
    ai_stopped && return 0
    rescue_guide_page
    return 0
}

# ------------------------------------------------------------
# 引导式（用户能操作）：问一句，再按选择执行
# ------------------------------------------------------------
guided_wired() {
    clear
    ui_title "$(t rescue_wired_title)"
    ui_line "$(t rescue_wired_trying)"
    ui_rule
    if net_up_wired_dhcp && wait_online 20; then
        rescue_bring_up_ssh
        return 0
    fi
    ui_line "$(t rescue_wired_fail)"
    ui_rule
    press_any_key "$(t press_any)" || true
    return 1
}

guided_phone_hotspot() {
    # 关键修复：改成"扫描 → 选你的手机热点 → 输密码"。
    # 4.x 是显示一个**随机生成**的热点名让用户去改手机热点名，用户当然连不上。
    clear
    ui_title "$(t rescue_s2_title)"
    ui_line "$(t rescue_s2_pick)"
    ui_rule
    press_any_key "$(t press_any)" || true
    if wifi_connect_flow; then
        rescue_bring_up_ssh
        return 0
    fi
    return 1
}

guided_pc_hotspot() {
    local ssid pass
    ssid="$(hotspot_ssid)"; pass="$(hotspot_pass)"
    clear
    ui_title "$(t rescue_s3_title)"
    ui_line "$(t rescue_s3_ask)"
    ui_line "$(t rescue_ssid_label)$ssid"
    ui_line "$(t rescue_pass_label)$pass"
    ui_nav
    if ! confirm "$(t rescue_s3_confirm)"; then
        return 1
    fi
    if start_pc_hotspot "$ssid" "$pass"; then
        ui_line "$(t rescue_s3_started)"
        ui_line "$(t rescue_s3_join_hint)"
        ui_rule
        press_any_key "$(t press_any)" || true
        rescue_bring_up_ssh
        return 0
    fi
    ui_line "$(t rescue_s3_fail)"
    ui_rule
    press_any_key "$(t press_any)" || true
    return 1
}

rescue_guided() {
    local c
    while true; do
        clear
        ui_title "$(t rescue_guided_title)"
        ui_line "$(t rescue_guided_ask)"
        ui_rule
        ui_line "$(t rescue_guided_1)"
        ui_line "$(t rescue_guided_2)"
        ui_line "$(t rescue_guided_3)"
        ui_line "$(t rescue_guided_4)"
        ui_line "$(t rescue_guided_5)"
        ui_nav
        c="$(read_choice 5)"
        case "$c" in
            NUM:1|CH:1) guided_wired || continue ;;
            NUM:2|CH:2) clear; wifi_screen ;;
            NUM:3|CH:3) guided_phone_hotspot || continue ;;
            NUM:4|CH:4) guided_pc_hotspot || continue ;;
            NUM:5|CH:5) rescue_guide_page; return 0 ;;
            ESC|CH:X|CH:x) return 0 ;;
            *) : ;;
        esac
    done
}

# ------------------------------------------------------------
# 入口
# ------------------------------------------------------------
run_rescue() {
    clear
    ui_title "$(t rescue_title)"
    ui_line "$(t rescue_intro1)"
    ui_line "$(t rescue_esc_hint)"
    ui_rule

    if [ -f "$LOCK_FILE" ]; then
        ui_line "$(t rescue_lockfile)"
        ui_line "$LOCK_FILE"
        ui_rule
        press_any_key "$(t press_any)" || return 0
        return 0
    fi

    # 急停标记还在：明确告诉用户为什么急救会跳过，并给出清除入口
    if ai_stopped; then
        ui_line "$(t rescue_estop_on)$(cfg_get ai_estop_file)"
        ui_line "$(t rescue_estop_how)"
        ui_rule
        press_any_key "$(t press_any)" || return 0
        return 0
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        ui_line "$(t rescue_no_config)"
        sleep 2
    fi

    local rc=0
    rescue_ask_can_type || rc=$?
    case "$rc" in
        2) return 0 ;;          # 用户按 ESC：回主菜单，不进任何流程
        0) rescue_guided ;;
        *) rescue_auto ;;
    esac
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_rescue
fi
