#!/bin/bash
# ============================================================
# AI-Boot 5.2 SSH 模块
#   - ssh_port / ssh_allow_root / ai_user 三个配置键在这里真正生效
#     （4.0 里它们只存在于配置文件里，没有任何代码读）
#   - ESC / X = 返回上一级
# ============================================================
set -u
source /usr/local/bin/ai-boot-common.sh
source /usr/local/bin/ai-password.sh

# LOCK_FILE 由 ai-boot-common.sh 统一定义（原先两个模块各写一份）
SSHD_DROPIN="/etc/ssh/sshd_config.d/aiboot.conf"

get_ip() {
    ip -4 addr show 2>/dev/null \
        | grep -oE '(inet )[0-9.]+' \
        | awk '{print $2}' \
        | grep -v '^127\.' \
        | head -n 1
}

# apply_sshd_config 已收归 ai-boot-common.sh（急救路径也要用它）

start_ssh_service() {
    # 先自愈"缺 sshd 权限分离用户"这个致命问题（5.1）
    command -v ensure_privsep_user >/dev/null 2>&1 && ensure_privsep_user
    command -v ensure_system_ready >/dev/null 2>&1 && ensure_system_ready
    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
        ssh-keygen -A 2>/dev/null || true
    fi
    apply_sshd_config || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart ssh 2>/dev/null \
            || systemctl restart sshd 2>/dev/null \
            || systemctl start ssh 2>/dev/null \
            || systemctl start sshd 2>/dev/null \
            || service ssh start
    else
        service ssh start
    fi
}

ssh_listening() {
    local port
    port="$(cfg_get ssh_port)"; [ -n "$port" ] || port=22
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -q ":$port "
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -q ":$port "
    else
        return 0
    fi
}

show_connection_card() {
    local ip port user
    ip="$(get_ip || true)"
    port="$(cfg_get ssh_port)"; [ -n "$port" ] || port=22
    user="$(ai_user_name)"

    ui_title "$(t ssh_title)"
    ui_blank
    ui_line "$(ui_pad "$(t ssh_ip)" 8): ${ip:-$(t ssh_nonet)}"
    ui_line "$(ui_pad "$(t ssh_port)" 8): $port"
    ui_line "$(ui_pad "$(t ssh_user)" 8): $user"
    if [ "$port" = "22" ]; then
        ui_line "$(ui_pad "$(t ssh_cmd)" 8): ssh $user@${ip:-<IP>}"
    else
        ui_line "$(ui_pad "$(t ssh_cmd)" 8): ssh -p $port $user@${ip:-<IP>}"
    fi
    ui_blank
    ui_line "$(ui_pad "$(t ssh_pw)" 8): ${CURRENT_SSH_PASSWORD:-$(read_pass_file || echo "-")}"
    ui_line "$(t ssh_readme): /usr/local/share/ai-boot/AI-README.txt"
    ui_blank
    ui_line "$(t common_pw_warning)"
    ui_rule
}

run_ssh() {
    local mode="${1:-auto}"

    if [ -f "$LOCK_FILE" ]; then
        clear
        ui_title "$(t ssh_locked_title)"
        ui_line "$(t ssh_locked_file)$LOCK_FILE"
        ui_line "$(t ssh_locked_hint)"
        ui_rule
        press_any_key || return 0
        return 1
    fi

    prepare_ssh_password "$mode" || return 1
    start_ssh_service
    sleep 1
    clear
    show_connection_card
    # 密码默认沿用本次开机的那个；想换就按 N（给 10 秒，不按就继续）
    ui_line "$(t ssh_new_pw)"
    printf '> '
    local c
    c="$(read_choice 0 3 1)"
    case "$c" in
        CH:N|CH:n)
            prepare_ssh_password new || true
            clear
            show_connection_card
            press_any_key || true
            ;;
        *) : ;;
    esac

    if ! ssh_listening; then
        echo
        echo "$(t ssh_not_listening)"
        echo "$(t ssh_not_listening_hint)"
        press_any_key || return 0
    fi

    /usr/local/bin/ai-monitor.sh
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --file) run_ssh file ;;
        --new)  run_ssh new ;;
        *)      run_ssh auto ;;
    esac
fi
