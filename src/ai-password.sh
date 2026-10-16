#!/bin/bash
# AI Boot Pro —— 救援启动盘系统
# Copyright (c) 2026 sxzxdpy  <https://github.com/listenablehfcd>
# SPDX-License-Identifier: MIT
# ============================================================
# AI-Boot 5.2 密码模块
#   - 用户名不再硬编码 "ai"，改用配置里的 ai_user
#   - ESC / X = 返回上一级
# ============================================================
set -u
source /usr/local/bin/ai-boot-common.sh

PASSWORD_LENGTH=16

new_password() {
    gen_random_password "$PASSWORD_LENGTH"
}

# ai_user_name() 已移到 ai-boot-common.sh，避免和 ai-monitor.sh 各写一份导致行为不一致。

read_pass_file() {
    if [ -f "$PASS_FILE" ]; then
        head -n 1 "$PASS_FILE" | tr -d '\r\n'
        return 0
    fi
    return 1
}

write_pass_file() {
    local pass="$1"
    if [ "$CFG_WRITABLE" != "1" ]; then
        echo "$(t pw_readonly_note)"
        return 1
    fi
    mkdir -p "$(dirname "$PASS_FILE")" 2>/dev/null || true
    # printf 而不是 echo：用户手输的密码恰好是 "-n"/"-e" 时，echo 会把它当选项，
    # 写出 0 字节或只写一个换行 → 密码文件是空的。
    ( umask 077; printf '%s\n' "$pass" > "$PASS_FILE" ) 2>/dev/null || return 1
    # umask 只对**新建**文件生效（POSIX：截断已存在文件不改权限），
    # 而 PASS_FILE 可能是 4.0 遗留的、或从别处拷来的。补一刀显式收紧。
    chmod 600 "$PASS_FILE" 2>/dev/null || true
    return 0
}

set_ai_password() {
    local pass="$1"
    local user
    user="$(ai_user_name)"
    if ! getent passwd "$user" >/dev/null 2>&1; then
        echo "$(t pw_no_user_a)$user$(t pw_no_user_b)"
        return 1
    fi
    printf '%s:%s\n' "$user" "$pass" | chpasswd 2>/dev/null || {
        echo "$(t pw_chpasswd_fail)"
        return 1
    }
    return 0
}

password_file_menu() {
    local saved c
    saved="$(read_pass_file || true)"

    while true; do
        clear
        ui_title "$(t pw_title)"
        ui_line "$(t pw_ssh_user)$(ai_user_name)"
        if [ -n "$saved" ]; then
            ui_line "$(t pw_usb_found_a)$PASS_FILE$(t pw_usb_suffix)"
        else
            ui_line "$(t pw_usb_missing_a)$PASS_FILE$(t pw_usb_suffix)"
        fi
        ui_rule
        ui_line "$(t pw_opt1)"
        ui_line "$(t pw_opt2)"
        ui_rule
        ui_line "$(t common_pw_warning)"
        ui_nav
        printf '> '

        c="$(read_choice 2)"
        case "$c" in
            ESC|EOF|CH:X|CH:x|CH:3)
                return 0 ;;
            NUM:1)
                if [ -n "$saved" ]; then
                    set_ai_password "$saved" && echo "$(t pw_used_usb)"
                else
                    echo "$(t pw_usb_absent)"
                fi
                press_any_key || return 0
                ;;
            NUM:2)
                if ! read_secret "$(t pw_new_prompt)"; then
                    continue
                fi
                local newpass="$READ_LINE"
                if [ -n "$newpass" ]; then
                    if set_ai_password "$newpass"; then
                        write_pass_file "$newpass" || true
                        echo "$(t pw_new_applied)"
                        saved="$newpass"
                    fi
                else
                    echo "$(t pw_empty)"
                fi
                press_any_key || return 0
                ;;
            *)
                : ;;
        esac
    done
}

# root 密码与 ai 密码绑定相同（要求：root 密码默认与 AI 的相同）
set_root_password() {
    local pass="$1"
    printf 'root:%s\n' "$pass" | chpasswd 2>/dev/null || return 1
    return 0
}

# 把本次开机生成的 SSH 密码**明确打出来**。看不到密码 = SSH 用不了。
show_password_box() {
    local pass="$1"
    echo
    ui_rule
    ui_line "$(ui_pad "$(t ssh_pw)" 6): $pass"
    ui_line "$(ui_pad "$(t ssh_user)" 6): $(ai_user_name)  ($(t ssh_root_same))"
    ui_rule
    echo
}

# sshd 是否已经在监听（本模块自足，不依赖 ai-ssh.sh）
sshd_up() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -q ":$(cfg_get ssh_port) " && return 0
    fi
    command -v pgrep >/dev/null 2>&1 && pgrep -x sshd >/dev/null 2>&1 && return 0
    return 1
}

prepare_ssh_password() {
    local mode="${1:-auto}"
    local saved pass newpass

    case "$mode" in
        file)
            saved="$(read_pass_file || true)"
            if [ -n "$saved" ]; then
                set_ai_password "$saved"
            else
                echo "$(t pw_usb_absent)"
                press_any_key || return 0
                return 1
            fi
            ;;
        new)
            # 原来是裸 read -r：密码会明文回显在屏幕上，而且 ESC 取消不了，
            # 和全系统“ESC 一下返回上一级”的约定不一致。改用 read_secret。
            if ! read_secret "$(t pw_new_ssh_prompt)"; then
                echo "$(t pw_cancelled)"
                sleep 1
                return 1
            fi
            newpass="$READ_LINE"
            if [ -n "$newpass" ]; then
                set_ai_password "$newpass" || return 1
                write_pass_file "$newpass" || true
            else
                echo "$(t pw_empty)"
                sleep 1
                return 1
            fi
            ;;
        auto|*)
            # 5.0：本次开机已经生成过密码、而且 sshd 已经在监听 → **沿用**它。
            # 4.x 每次进 1.SSH 都重新生成：操作者刚把密码抄下来或告诉远程 AI，
            # 回一趟菜单再进来密码就悄悄变了，AI 立刻连不上（审计已列）。
            saved="$(read_pass_file 2>/dev/null || true)"
            if [ -n "$saved" ] && sshd_up; then
                set_ai_password "$saved" || true
                set_root_password "$saved" || true
                CURRENT_SSH_PASSWORD="$saved"
                export CURRENT_SSH_PASSWORD
                echo "$(t pw_reuse)"
                show_password_box "$saved"
                return 0
            fi
            # 4.1 的 bug：这里生成了密码、写进了 shadow，却**从来没有显示**
            # 也没有落盘 —— 用户在界面上根本看不到密码，SSH 等于连不上。
            pass="$(new_password)"
            set_ai_password "$pass" || return 1
            set_root_password "$pass" || true
            write_pass_file "$pass" || true
            CURRENT_SSH_PASSWORD="$pass"
            export CURRENT_SSH_PASSWORD
            show_password_box "$pass"
            ;;
    esac
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --file) password_file_menu ;;
        *)      password_file_menu ;;
    esac
fi
