#!/bin/bash
# ============================================================
# AI-Boot 5.2 引导配置（Guided configuration）
#
# 它要解决的问题：用户面对一台坏了的电脑，不知道该先做什么。
# 所以这里**不解释**，而是**提问**：从最宽的条件问起，一步步把范围收窄
# （条件从充足变得严苛），每一步都真的去试、并且验证"能不能上互联网"。
#
# 第 1 问固定为：
#     你能自主连接到互联网吗？（不依赖于现有设置）
#        1 能   2 不能
#   ├ 能   → 你打算用哪种方式？  ①有线 ②自己的 WiFi ③手机 USB 共享 ④手机蓝牙
#   └ 不能 → 你手边有能提供网络的设备吗？
#              ①有手机(能开热点) ②有另一台能上网的电脑 ③都没有
#
# 任一方式成功 → 起 sshd → 连接信息页 → 监视页
# 失败 → 说清原因 → 自动回到上一问，让用户换一种方式
# ============================================================
set -u
source /usr/local/bin/ai-boot-common.sh
source /usr/local/bin/ai-network.sh
source /usr/local/bin/ai-password.sh
source /usr/local/bin/ai-ssh.sh

# ------------------------------------------------------------
# 真的验证"能上互联网"，而不只是"拿到了 IP"
# ------------------------------------------------------------
gd_online() {
    if command -v wait_online >/dev/null 2>&1; then
        wait_online 25
        return $?
    fi
    ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 && return 0
    ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 && return 0
    return 1
}

gd_try_screen() {
    clear
    ui_title "$(t gd_title)"
    ui_line "$1"
    [ -n "${2:-}" ] && ui_line "$2"
    ui_rule
    ui_line "$(t gd_checking)"
}

# 成功：起 sshd，进入连接信息页与监视页
gd_success() {
    clear
    ui_title "$(t gd_ok)"
    ui_line "$(t gd_ok_line)"
    ui_rule
    press_any_key "$(t press_any)" || return 0
    /usr/local/bin/ai-ssh.sh auto
    return 0
}

# 失败：说原因，回上一问
gd_fail() {
    ui_rule
    ui_line "$1"
    ui_rule
    press_any_key "$(t press_any)" || return 0
    return 1
}

# ------------------------------------------------------------
# ②-1 有线
# ------------------------------------------------------------
gd_wired() {
    gd_try_screen "$(t gd_wired_1)" "$(t gd_wired_2)"
    net_up_wired_dhcp || true
    if gd_online; then gd_success; return 0; fi
    gd_fail "$(t gd_wired_fail)"
}

# ------------------------------------------------------------
# ②-2 自己的 WiFi（扫描 → 选网 → 输密码）
# ------------------------------------------------------------
gd_wifi() {
    clear
    ui_title "$(t gd_title)"
    ui_line "$(t gd_wifi_1)"
    ui_rule
    press_any_key "$(t press_any)" || return 1
    wifi_connect_flow || return 1
    if gd_online; then gd_success; return 0; fi
    gd_fail "$(t gd_wifi_fail)"
}

# ------------------------------------------------------------
# ②-3 手机 USB 共享（USB tethering）
# ------------------------------------------------------------
gd_usb_tether() {
    local ifc
    gd_try_screen "$(t gd_usb_1)" "$(t gd_usb_2)"
    # 拔插一次以触发枚举，然后等接口出现（RNDIS / NCM / CDC-ECM）
    sleep 3
    ifc="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' \
           | grep -E '^(usb|enp|eth)[0-9]*' \
           | grep -vE "$(wifi_iface 2>/dev/null || echo __none__)" | head -n1)"
    if [ -z "$ifc" ]; then
        gd_fail "$(t gd_usb_fail)"
        return 1
    fi
    ip link set "$ifc" up 2>/dev/null || true
    if command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd -n "$ifc" >/dev/null 2>&1 || true
    elif command -v dhclient >/dev/null 2>&1; then
        dhclient "$ifc" >/dev/null 2>&1 || true
    fi
    sleep 5
    if gd_online; then gd_success; return 0; fi
    gd_fail "$(t gd_usb_fail)"
}

# ------------------------------------------------------------
# ②-4 手机蓝牙共享：本机没有蓝牙栈，只能给指引
# ------------------------------------------------------------

# ------------------------------------------------------------
# ③-1 手机开热点，本机去连（扫描 → 选你的手机 → 输密码）
# ------------------------------------------------------------
gd_phone_hotspot() {
    clear
    ui_title "$(t gd_title)"
    ui_line "$(t gd_ph_1)"
    ui_line "$(t gd_ph_2)"
    ui_rule
    press_any_key "$(t press_any)" || return 1
    wifi_connect_flow || return 1
    if gd_online; then gd_success; return 0; fi
    gd_fail "$(t gd_ph_fail)"
}

# ------------------------------------------------------------
# ③-2 本机开热点，另一台能上网的电脑连过来并共享网络
# ------------------------------------------------------------
gd_pc_share() {
    local ssid pass
    ssid="$(hotspot_ssid)"; pass="$(hotspot_pass)"
    clear
    ui_title "$(t gd_share_title)"
    ui_line "$(t gd_share_1)"
    ui_line "$(t gd_share_2)"
    ui_rule
    ui_line "$(t rescue_ssid_label)$ssid"
    ui_line "$(t rescue_pass_label)$pass"
    ui_rule
    ui_line "$(t gd_share_3)"
    ui_nav
    confirm "$(t gd_share_confirm)" || return 1
    start_pc_hotspot "$ssid" "$pass" || { gd_fail "$(t rescue_s3_fail)"; return 1; }
    clear
    ui_title "$(t gd_share_title)"
    ui_line "$(t rescue_ssid_label)$ssid"
    ui_line "$(t rescue_pass_label)$pass"
    ui_rule
    ui_line "$(t gd_share_4)"
    ui_rule
    ui_line "$(t gd_share_5)"
    press_any_key "$(t press_any)" || return 1
    # 另一台电脑共享出网络后，本机会经由热点拿到地址
    if gd_online; then gd_success; return 0; fi
    gd_fail "$(t gd_share_fail)"
}

# ------------------------------------------------------------
# ③-3 什么都没有：本地指引（不落到 shell）
# ------------------------------------------------------------
gd_local_guide() {
    clear
    ui_title "$(t gd_local_title)"
    ui_line "$(t gd_local_1)"
    ui_line "$(t gd_local_2)"
    ui_rule
    ui_line "$(t gd_local_3)"
    ui_line "$(t gd_local_4)"
    ui_rule
    ui_line "$(t gd_local_5)"
    ui_nav
    press_any_key "$(t press_any)" || return 0
    if confirm "$(t rescue_s4_shell_confirm)"; then
        /usr/local/bin/ai-shell.sh
    fi
    return 0
}

# ------------------------------------------------------------
# 第 2 问：能自主上网时，用哪种方式
# ------------------------------------------------------------
gd_branch_can() {
    local c
    while true; do
        clear
        ui_title "$(t gd_title)"
        ui_line "$(t gd_q2)"
        ui_rule
        ui_line "$(t gd_q2_1)"
        ui_line "$(t gd_q2_2)"
        ui_line "$(t gd_q2_3)"
        ui_nav
        c="$(read_choice 3)"
        case "$c" in
            NUM:1|CH:1) gd_wired && return 0 ;;
            NUM:2|CH:2) gd_wifi && return 0 ;;
            NUM:3|CH:3) gd_usb_tether && return 0 ;;
            ESC|CH:X|CH:x) return 2 ;;
            *) : ;;
        esac
    done
}

# ------------------------------------------------------------
# 第 3 问：不能自主上网时，手边有什么设备
# ------------------------------------------------------------
gd_branch_cannot() {
    local c
    while true; do
        clear
        ui_title "$(t gd_title)"
        ui_line "$(t gd_q3)"
        ui_rule
        ui_line "$(t gd_q3_1)"
        ui_line "$(t gd_q3_2)"
        ui_line "$(t gd_q3_3)"
        ui_nav
        c="$(read_choice 3)"
        case "$c" in
            NUM:1|CH:1) gd_phone_hotspot && return 0 ;;
            NUM:2|CH:2) gd_pc_share && return 0 ;;
            NUM:3|CH:3) gd_local_guide; return 0 ;;
            ESC|CH:X|CH:x) return 2 ;;
            *) : ;;
        esac
    done
}

# ------------------------------------------------------------
# 入口：第 1 问
# ------------------------------------------------------------
run_guided() {
    local c rc
    while true; do
        clear
        ui_title "$(t gd_title)"
        ui_line "$(t gd_q1)"
        ui_line "$(t gd_q1b)"
        ui_rule
        ui_line "$(t gd_q1_1)"
        ui_line "$(t gd_q1_2)"
        ui_nav
        c="$(read_choice 2)"
        case "$c" in
            NUM:1|CH:1) gd_branch_can;  rc=$? ;;
            NUM:2|CH:2) gd_branch_cannot; rc=$? ;;
            ESC|CH:X|CH:x) return 0 ;;
            *) rc=1 ;;
        esac
        [ "${rc:-1}" = "2" ] && continue   # 子分支按 ESC：回到第 1 问
        return 0
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_guided
fi
