#!/bin/bash
# AI Boot Pro —— 救援启动盘系统
# Copyright (c) 2026 sxzxdpy  <https://github.com/listenablehfcd>
# SPDX-License-Identifier: MIT
# ============================================================
# AI-Boot 5.2 工具模块
#   - 所有子界面 ESC / X = 返回上一级
#   - 文件浏览器不再无限递归、也不再只能靠输入 X 退出
#   - Windows 那几项在 4.0 里只是 echo 一句提示，这里明确标注“仅提示”，
#     不再让人误以为已经实现（诚实优先于好看）
# ============================================================
set -u
source /usr/local/bin/ai-boot-common.sh

windows_tools_menu() {
    local c
    while true; do
        clear
        ui_title "$(t tools_win_title)"
        ui_line "$(t tools_w1)"
        ui_line "$(t tools_w2)"
        ui_line "$(t tools_w3)"
        ui_line "$(t tools_w4)"
        ui_line "$(t tools_w5)"
        ui_nav
        printf '> '

        c="$(read_choice 5)"
        case "$c" in
            ESC|EOF|CH:X|CH:x)
                return 0 ;;
            NUM:1)
                clear
                ui_title "$(t tools_disk_title)"
                lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null || echo "$(t tools_nolsblk)"
                ui_rule
                press_any_key "$(t press_any)" || return 0
                ;;
            NUM:2)
                clear
                ui_title "$(t tools_mnt_title)"
                ui_line "$(t tools_mnt_ex)"
                ui_rule
                if ! read_line "$(t tools_mnt_prompt)"; then continue; fi
                local p="$READ_LINE"
                [ -z "$p" ] && continue
                mkdir -p /mnt/win 2>/dev/null || true
                if mount "$p" /mnt/win 2>/dev/null; then
                    ui_line "$(t tools_mnt_ok)"
                else
                    ui_line "$(t tools_mnt_fail)"
                    ui_line "$(t tools_mnt_r1)"
                    ui_line "$(t tools_mnt_r2)"
                    ui_line "$(t tools_mnt_r3)mount -t ntfs-3g $p /mnt/win"
                fi
                ui_rule
                press_any_key "$(t press_any)" || return 0
                ;;
            NUM:3)
                clear
                ui_title "$(t tools_fix_title)"
                ui_line "$(t tools_fix_line)"
                ui_rule
                ui_line "$(t tools_fix_s1)bcdboot C:\\Windows /s S: /f UEFI"
                ui_line "$(t tools_fix_s2)"
                ui_line "$(t tools_fix_s3)"
                ui_line "   sudo apt-get install -y chntpw"
                ui_line "$(t tools_fix_s5)"
                ui_line "   sudo mount /dev/sdX1 /mnt/efi"
                ui_line "$(t tools_fix_s7a)/mnt/efi/EFI/Microsoft/Boot/bootmgfw.efi$(t tools_fix_s7b)"
                ui_rule
                press_any_key "$(t press_any)" || return 0
                ;;
            NUM:4)
                clear
                ui_title "$(t tools_bak_title)"
                ui_line "$(t tools_bak_line)"
                ui_rule
                ui_line "rsync -a --info=progress2 /mnt/win/Users $AI_BOOT_DIR/backup/"
                ui_rule
                press_any_key "$(t press_any)" || return 0
                ;;
            NUM:5)
                clear
                ui_title "$(t tools_iso_title)"
                ui_line "$(t tools_iso_line)"
                ui_rule
                ui_line "$(t tools_iso_s1)"
                ui_line "dd if=windows.iso of=/dev/sdX bs=4M status=progress oflag=sync"
                ui_rule
                ui_line "$(t tools_iso_warn)"
                ui_rule
                press_any_key "$(t press_any)" || return 0
                ;;
            *)
                : ;;
        esac
    done
}

# 文件浏览器：循环 + 上级 + ESC（用 find 列举，兼容带空格的目录名）
file_browser() {
    local cwd c line n
    cwd="/"

    while true; do
        local -a dirs=()
        local d
        while IFS= read -r d; do
            dirs+=("$d")
        done < <(find "$cwd" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

        clear
        ui_title "$(t tools_browse_title)"
        ui_line "$(t tools_cwd)$cwd"
        ui_rule
        if [ "${#dirs[@]}" -eq 0 ]; then
            ui_line "$(t tools_nodirs)"
        else
            local i
            for ((i = 0; i < ${#dirs[@]}; i++)); do
                ui_line "$(printf '%3d. %s %.60s' "$((i + 1))" "$(t tools_dir_tag)" "${dirs[$i]##*/}")"
            done
        fi
        ui_rule
        # wc -l 在部分实现里会补前导空格，显示成“另有      5 个文件”
        n="$(find "$cwd" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
        ui_line "$(t tools_other_a)$n$(t tools_other_b)"
        ui_rule
        ui_line "$(t tools_browse_nav)"
        ui_nav
        printf '> '

        c="$(read_choice "${#dirs[@]}")"
        case "$c" in
            ESC|EOF|CH:X|CH:x)
                return 0 ;;
            CH:U|CH:u)
                d="$(cd "$cwd/.." 2>/dev/null && pwd)" || d="/"
                cwd="$d"
                ;;
            CH:P|CH:p)
                clear
                ls -la "$cwd" 2>/dev/null || echo "$(t tools_list_fail)"
                ui_rule
                press_any_key "$(t press_any)" || return 0
                ;;
            NUM:*)
                n="${c#NUM:}"
                if [ "$n" -ge 1 ] && [ "$n" -le "${#dirs[@]}" ]; then
                    cwd="${dirs[$((n - 1))]}"
                else
                    echo "$(t tools_no_dir_a)$n$(t tools_no_dir_b)"
                    sleep 1
                fi
                ;;
            *)
                : ;;
        esac
    done
}

backup_to_share() {
    local c src
    while true; do
        clear
        ui_title "$(t tools_backup_title)"
        ui_line "$(t tools_bak1)$AI_BOOT_DIR/backup"
        ui_line "$(t tools_bak2)"
        ui_nav
        printf '> '

        c="$(read_choice 2)"
        case "$c" in
            ESC|EOF|CH:X|CH:x)
                return 0 ;;
            NUM:1)
                if [ "$CFG_WRITABLE" != "1" ]; then
                    clear
                    ui_title "$(t tools_bak_no)"
                    ui_line "$(t tools_bak_ro)$AI_BOOT_DIR"
                    ui_rule
                    press_any_key "$(t press_any)" || return 0
                    continue
                fi
                if ! read_line "$(t tools_bak_prompt)"; then continue; fi
                src="$READ_LINE"
                [ -z "$src" ] && continue
                if [ ! -e "$src" ]; then
                    echo "$(t tools_no_path)$src"
                    press_any_key "$(t press_any)" || return 0
                    continue
                fi
                mkdir -p "$AI_BOOT_DIR/backup" 2>/dev/null || true
                # 原来写成 `cp -av ... | tail -20`，退出码是 tail 的（恒为 0），
                # 于是 FAT32/磁盘满/权限不足导致 cp 失败时照样打印"完成。"。
                # 先把输出收进变量再判断 cp 自己的退出码。
                # 备份可能几分钟到几十分钟：必须能看到进度、也必须能取消。
                # 4.x 把输出全收进变量，期间屏幕毫无反应，用户以为死机去断电，
                # 反而毁掉备份（审计已列）。
                local tmplog rc cpid
                tmplog="$(mktemp 2>/dev/null || echo "/tmp/ai-backup.$$")"
                cp -av "$src" "$AI_BOOT_DIR/backup/" > "$tmplog" 2>&1 &
                cpid=$!
                rc=0
                while kill -0 "$cpid" 2>/dev/null; do
                    printf '\r%s %s  %s' "$(t tools_bak_progress)" "$(wc -l < "$tmplog" | tr -d ' ')" "$(t tools_bak_esc)"
                    case "$(read_choice 0 1 1)" in
                        ESC|CH:X|CH:x)
                            printf '\n'
                            if confirm "$(t tools_bak_abort)"; then
                                kill "$cpid" 2>/dev/null || true
                                wait "$cpid" 2>/dev/null || true
                                rc=130
                                break
                            fi ;;
                    esac
                done
                if [ "$rc" = "0" ]; then
                    wait "$cpid" 2>/dev/null || rc=$?
                fi
                printf '\r%-60s\n' ' '
                tail -n 12 "$tmplog" 2>/dev/null
                rm -f "$tmplog" 2>/dev/null || true
                if [ "$rc" = "0" ]; then
                    echo "$(t tools_done)"
                elif [ "$rc" = "130" ]; then
                    echo "$(t tools_bak_cancelled)"
                else
                    echo "$(t tools_bak_failed)"
                fi
                press_any_key "$(t press_any)" || return 0
                ;;
            NUM:2)
                clear
                ui_title "$(t tools_smb_title)"
                ui_line "$(t tools_smb_line)"
                ui_rule
                ui_line "mkdir -p /mnt/smb"
                ui_line "$(t tools_smb_cmd)"
                ui_line "$(t tools_smb_cp)"
                ui_rule
                ui_line "$(t tools_smb_note)"
                ui_rule
                press_any_key "$(t press_any)" || return 0
                ;;
            *)
                : ;;
        esac
    done
}

self_check() {
    local tmp
    clear
    ui_title "$(t tools_check_title)"

    # 这里原来是 `cmd | sed ... || ui_line "  无"`。
    # 管道的退出码取的是**最后一个命令**，sed 永远成功，
    # 所以“无”这条分支一次都不会走到，空结果就是一片空白。
    ui_line "$(t tools_net)"
    tmp="$(ip -4 addr show 2>/dev/null | grep -oE '(inet )[0-9.]+.*' | sed 's/^/  /')"
    if [ -n "$tmp" ]; then printf '%s\n' "$tmp"; else ui_line "$(t tools_none)"; fi

    ui_line "$(t tools_route)"
    tmp="$(ip route show default 2>/dev/null | sed 's/^/  /')"
    if [ -n "$tmp" ]; then printf '%s\n' "$tmp"; else ui_line "$(t tools_none)"; fi

    ui_line "$(t tools_iw)"
    tmp="$(iw dev 2>/dev/null | sed 's/^/  /')"
    if [ -n "$tmp" ]; then printf '%s\n' "$tmp"; else ui_line "$(t tools_no_iw)"; fi

    # 给一句明确结论，别只堆原始输出：用户/AI 一眼要看的就是"SSH 到底起来了没"
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$(cfg_get ssh_port) "; then
        ui_line "$(t tools_ssh_yes)"
    else
        ui_line "$(t tools_ssh_no)"
    fi
    ui_line "$(t tools_sshline_a)$(cfg_get ssh_port)$(t tools_sshline_b)"
    if command -v ss >/dev/null 2>&1; then
        tmp="$(ss -ltn 2>/dev/null | sed 's/^/  /')"
        if [ -n "$tmp" ]; then printf '%s\n' "$tmp"; else ui_line "$(t tools_none)"; fi
    else
        ui_line "$(t tools_no_ss)"
    fi
    ui_rule
    ui_line "$(t tools_disk)"
    tmp="$(lsblk -o NAME,SIZE,TYPE,FSTYPE 2>/dev/null | head -n 12 | sed 's/^/  /')"
    if [ -n "$tmp" ]; then printf '%s\n' "$tmp"; else ui_line "$(t tools_no_lsblk)"; fi
    ui_rule
    ui_line "$(t tools_lock)$([ -f "$LOCK_FILE" ] && echo "$(t tools_exist)" || echo "$(t tools_absent)")"
    ui_line "$(t tools_donefile)$([ -f "$(cfg_get ai_done_file)" ] && echo "$(t tools_exist)" || echo "$(t tools_absent)")"
    ui_line "$(t tools_estopfile)$([ -f "$(cfg_get ai_estop_file)" ] && echo "$(t tools_exist)" || echo "$(t tools_absent)")"
    ui_line "$(t tools_log)$LOG_FILE"
    ui_line "$(t tools_conf)$CONFIG_FILE"
    ui_line "$(t tools_conf_w)$([ "$CFG_WRITABLE" = 1 ] && echo "$(t tools_yes)" || echo "$(t tools_no)")"
    ui_line "$(t tools_conf_p)$([ "$CFG_VOLATILE" = 1 ] && echo "$(t tools_no)" || echo "$(t tools_yes)")"
    ui_rule
    press_any_key "$(t press_any)" || return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --windows) windows_tools_menu ;;
        --browser) file_browser ;;
        --backup)  backup_to_share ;;
        --check)   self_check ;;
        *)         self_check ;;
    esac
fi
