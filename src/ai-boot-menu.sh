#!/bin/bash
# AI Boot Pro —— 救援启动盘系统
# Copyright (c) 2026 sxzxdpy  <https://github.com/listenablehfcd>
# SPDX-License-Identifier: MIT
# ============================================================
# AI-Boot 5.2 主菜单
#   统一交互约定：
#     ESC / X  = 返回上一级（在主菜单按 = 退出到命令行，并保证不会卡死在黑屏）
#     数字     = 直接选择
#     ENTER    = 确认 / 重绘
# ============================================================
set -u
source /usr/local/bin/ai-boot-common.sh

AUTO_RESCUE_SECONDS=30

# ---------------- 大号数字倒计时 ----------------
DIG0="##### #   # #   # #   # #####"
DIG1="  #    ##     #     #   #####"
DIG2="#####     # ##### #     #####"
DIG3="#####     # #####     # #####"
DIG4="#   # #   # #####     #     #"
DIG5="##### #     #####     # #####"
DIG6="##### #     ##### #   # #####"
DIG7="#####     #     #     #     #"
DIG8="##### #   # ##### #   # #####"
DIG9="##### #   # #####     # #####"

digit_line() {
    local d="$1" row="$2" str=""
    case "$d" in
        0) str="$DIG0" ;; 1) str="$DIG1" ;; 2) str="$DIG2" ;;
        3) str="$DIG3" ;; 4) str="$DIG4" ;; 5) str="$DIG5" ;;
        6) str="$DIG6" ;; 7) str="$DIG7" ;; 8) str="$DIG8" ;;
        9) str="$DIG9" ;;
    esac
    printf '%s\n' "$str" | cut -c$((row * 6 + 1))-$((row * 6 + 5))
}

# 每次进主菜单先把"AI 登录所必需的系统状态"整好（家目录属主、/etc/hosts）
command -v ensure_system_ready >/dev/null 2>&1 && ensure_system_ready

draw_menu() {
    # 注意：进位变量不能叫 t —— 那会和翻译函数 t() 撞名，
    # 一旦被 shadow，$(t menu_countdown) 就会去执行一个数字。
    local secs="$1" row tens ones lt lo c1
    clear
    ui_rule

    if [ "$secs" -ge 0 ]; then
        tens=$((secs / 10)); ones=$((secs % 10))
        for row in 0 1 2 3 4; do
            lt="$(digit_line "$tens" "$row")"
            lo="$(digit_line "$ones" "$row")"
            if [ "$row" -eq 2 ]; then
                # 倒计时贴第一个框的最右边（放大、放右边、必须看得见）
                ui_line "$(printf '%s%s' "$(ui_pad "$(t menu_countdown)" $((UI_W - 12)))" "$lt $lo")"
            else
                ui_line "$(printf '%s%s' "$(ui_pad '' $((UI_W - 12)))" "$lt $lo")"
            fi
        done
        ui_line "$(printf '%s%s' "$(ui_pad '' $((UI_W - 22)))" "$(t menu_anykey)")"
        ui_rule
    fi

    # 标题：中文模式列数少（40 列），长标题会被截断，所以按列数给两个长度
    if [ "$UI_COLS" = "2" ]; then
        ui_line "${AI_BOOT_PRODUCT:-AI Boot Pro} $AI_BOOT_VERSION   RESCUE / REMOTE"
    else
        ui_line "${AI_BOOT_PRODUCT:-AI Boot Pro} $AI_BOOT_VERSION   RESCUE / REMOTE SYSTEM"
    fi
    ui_rule
    ui_blank
    # ---- 1. 整体配置：急救模式 + 引导配置 ----
    ui_line "$(t menu_overall)"
    if [ "$UI_COLS" = "2" ]; then
        c1=$((UI_W / 2))
        ui_line "$(ui_pad "$(t menu_a)" $c1)$(t menu_b)"
    else
        ui_line "$(ui_pad "$(t menu_a)" 33)$(t menu_b)"
    fi
    ui_blank
    # ---- 2. 单独配置：一项一项单独设置 ----
    ui_line "$(t menu_individual)"
    if [ "$UI_COLS" = "2" ]; then
        ui_line "$(ui_pad "$(t menu_1)" $c1)$(t menu_2)"
        ui_line "$(ui_pad "$(t menu_3)" $c1)$(t menu_4)"
        ui_line "$(ui_pad "$(t menu_5)" $c1)$(t menu_6)"
        ui_line "$(ui_pad "$(t menu_7)" $c1)$(t menu_8)"
    else
        ui_line "$(ui_pad "$(t menu_1)" 18)$(ui_pad "$(t menu_2)" 24)$(t menu_3)"
        ui_line "$(ui_pad "$(t menu_4)" 18)$(ui_pad "$(t menu_5)" 24)$(t menu_6)"
        ui_line "$(ui_pad "$(t menu_7)" 18)$(ui_pad "$(t menu_8)" 24)"
    fi
    ui_blank
    # ---- 3. 设置 ----
    ui_line "$(t menu_settings)"
    if [ "$UI_COLS" = "2" ]; then
        ui_line "$(ui_pad "$(t menu_c)" $c1)$(t menu_d)"
        ui_line "$(ui_pad "$(t menu_e)" $c1)$(t menu_f)"
        ui_line "$(ui_pad "$(t menu_g)" $c1)$(t menu_h)"
        ui_line "$(ui_pad "$(t menu_l)" $c1)$(t menu_r)"
        ui_line "$(t menu_s)"
    else
        ui_line "$(ui_pad "$(t menu_c)" 18)$(ui_pad "$(t menu_d)" 24)$(t menu_e)"
        ui_line "$(ui_pad "$(t menu_f)" 18)$(ui_pad "$(t menu_g)" 24)$(t menu_h)"
        ui_line "$(ui_pad "$(t menu_l)" 18)$(ui_pad "$(t menu_r)" 24)$(t menu_s)"
    fi
    ui_blank
    ui_rule
    ui_line "$(t menu_nav1)"
    ui_line "$(t menu_nav2)"
    if [ "$CFG_WRITABLE" != "1" ]; then
        ui_line "$(t menu_readonly) $CONFIG_FILE"
    elif [ "$CFG_VOLATILE" = "1" ]; then
        ui_line "$(t menu_volatile)"
    fi
    ui_rule
    ui_line "$AI_BOOT_COPYRIGHT"
}

# ---------------- 退出 ----------------
# 4.0 在这里直接 exit 0，而 getty@tty1 被本服务 Conflicts 掉了，
# 于是菜单一退就只剩一块没有任何进程的黑屏。这里必须先落一个 shell，
# 并且 shell 退出后再把菜单拉起来，保证永远不会变成死屏。
exit_to_shell() {
    clear
    ui_title "$(t exit_title)"
    ui_line "$(t exit_line1)"
    ui_line "$(t exit_line2)"
    ui_blank
    ui_line "$(t cfg_path)$CONFIG_FILE"
    ui_rule
    if ! confirm "$(t exit_confirm)"; then
        return 1
    fi
    clear
    echo "AI-Boot $AI_BOOT_VERSION: menu closed, opening a shell..."
    echo "(type exit to return to the menu)"
    echo
    exec /bin/bash -c '/bin/bash -l; exec /usr/local/bin/ai-boot-menu.sh'
}

# ---------------- 分支 ----------------
handle_choice() {
    local c="$1"
    case "$c" in
        NUM:1)  /usr/local/bin/ai-ssh.sh ;;
        NUM:2)  /usr/local/bin/ai-network.sh --wifi ;;
        NUM:3)  /usr/local/bin/ai-rescue.sh ;;
        NUM:4)  /usr/local/bin/ai-password.sh --file ;;
        NUM:5)  /usr/local/bin/ai-shell.sh ;;
        NUM:6)  /usr/local/bin/ai-tools.sh --windows ;;
        NUM:7)  /usr/local/bin/ai-tools.sh --browser ;;
        NUM:8)  /usr/local/bin/ai-tools.sh --backup ;;
        NUM:9)  /usr/local/bin/ai-tools.sh --check ;;
        CH:A|CH:a) /usr/local/bin/ai-rescue.sh ;;
        CH:B|CH:b) /usr/local/bin/ai-guided.sh ;;
        CH:C|CH:c) /usr/local/bin/ai-config.sh --auto-config ;;
        CH:D|CH:d) /usr/local/bin/ai-config.sh --auto-save ;;
        CH:E|CH:e) /usr/local/bin/ai-config.sh --edit ;;
        CH:F|CH:f) /usr/local/bin/ai-config.sh --default ;;
        CH:G|CH:g) /usr/local/bin/ai-config.sh --usb-file ;;
        CH:L|CH:l) /usr/local/bin/ai-config.sh --language ;;
        CH:H|CH:h) /usr/local/bin/ai-help.sh ;;
        CH:R|CH:r) if confirm "$(t menu_confirm_reboot)"; then reboot; fi ;;
        CH:S|CH:s) if confirm "$(t menu_confirm_shutdown)"; then poweroff; fi ;;
        *) return 0 ;;
    esac
    return 0
}

run_menu() {
    local secs="$AUTO_RESCUE_SECONDS"
    local c="" cc=0 last_c=0 now

    while true; do
        draw_menu "$secs"
        c="$(read_choice 9 "$KEY_FOLLOW" 1)"

        case "$c" in
            TIMEOUT)
                # 只在没按过键时倒计时；到 0 自动进急救
                if [ "$secs" -ge 0 ]; then
                    secs=$((secs - 1))
                    if [ "$secs" -lt 0 ]; then
                        continue
                    fi
                    if [ "$secs" -eq 0 ]; then
                        /usr/local/bin/ai-rescue.sh
                        secs=-1
                    fi
                fi
                continue
                ;;            EOF)
                # 输入流结束（被 pipe 驱动 / 控制台消失）。直接退出进程，
                # 不能走“进 shell”那条路，否则外层会空转。
                exit 0
                ;;
            ESC|CH:X|CH:x|CH:Q|CH:q)
                exit_to_shell || true
                continue
                ;;
            ENTER)
                secs=-1
                continue
                ;;
        esac

        secs=-1

        # C x5 = 切换语言（沿用 4.0 的隐藏快捷键）
        if [ "$c" = "CH:C" ] || [ "$c" = "CH:c" ]; then
            now="$(date +%s)"
            if [ $((now - last_c)) -le 2 ]; then
                cc=$((cc + 1))
            else
                cc=1
            fi
            last_c="$now"
            if [ "$cc" -ge 5 ]; then
                cc=0
                /usr/local/bin/ai-config.sh --language
                continue
            fi
        else
            cc=0
        fi

        case "$c" in
            CH:*) handle_choice "$c" ;;
            NUM:*) handle_choice "$c" ;;
            *)    : ;;
        esac
        # 子界面（尤其是语言页）改的是配置文件，主菜单必须重读一次，
        # 否则界面永远停在旧语言 —— 这就是"选了中文主界面还是英文"。
        reload_language
        console_font_init 1
    done
}

# 让 ESC 在“刚启动”时也能立刻退出，而不是等倒计时
run_menu
