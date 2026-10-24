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
#
# 设置栏改版（真机反馈“设置页面乱成什么样了，我自己都迷糊”）：
#   9 项平铺（C/D/E/F/G/H/L/R/S）→ 3 个分组入口 + 1 行配置位置：
#     C. Config ...（查看/修改/默认值）  D. USB ...（位置/保存/选盘）
#     E. Other ...（语言/帮助/重启关机）
#   重启/关机/直接编辑文件都不再出现在顶级菜单，必须进二级页并二次确认。
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
    local secs="$1" row tens ones lt lo c1 aw
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
        # 提示语宽度要**实测**再补空格：原来写死 -22，而
        # "press any key to cancel" 是 23 列 → 每帧都被截成 "canc~"（真机截断问题）。
        aw="$(disp_width "$(t menu_anykey)")"
        ui_line "$(printf '%s%s' "$(ui_pad '' $((UI_W - aw)))" "$(t menu_anykey)")"
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
    # ---- 3. 设置：3 个分组入口（原来的 9 项平铺全部下沉到二级页）----
    ui_line "$(t menu_settings)"
    if [ "$UI_COLS" = "2" ]; then
        ui_line "$(ui_pad "$(t menu_c)" $c1)$(t menu_d)"
        ui_line "$(t menu_e)"
    else
        ui_line "$(ui_pad "$(t menu_c)" 18)$(ui_pad "$(t menu_d)" 24)$(t menu_e)"
    fi
    # 配置位置三态恒显：持久 / 只读 / 仅内存（重启会丢），绝不假装持久
    ui_line "$(cfg_status_text)"
    ui_blank
    ui_rule
    ui_line "$(t menu_nav1)"
    ui_line "$(t menu_nav2)"
    ui_rule
    ui_line "$AI_BOOT_COPYRIGHT"
    ui_project_url
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

# ---------------- E. Other：语言 / 帮助 / 重启关机 ----------------
# 连续两次 Y 才执行：重启/关机会让远程专家掉线，误按一次是灾难
double_confirm() {
    confirm "$1" || return 1
    confirm "$(t confirm_again)" || return 1
    return 0
}

power_page() {
    local c
    while true; do
        clear
        ui_title "$(t other_power)"
        ui_line "$(t other_reboot)"
        ui_line "$(t other_shutdown)"
        ui_nav
        printf '> '
        c="$(read_choice 2)"
        case "$c" in
            NUM:1)
                if double_confirm "$(t menu_confirm_reboot)"; then
                    clear
                    reboot 2>/dev/null || true
                fi
                ;;
            NUM:2)
                if double_confirm "$(t menu_confirm_shutdown)"; then
                    clear
                    poweroff 2>/dev/null || true
                fi
                ;;
            ESC|EOF|CH:X|CH:x) return 0 ;;
            *) : ;;
        esac
    done
}

other_page() {
    local c
    while true; do
        clear
        ui_title "$(t title_other)"
        ui_line "$(t other_lang)"
        ui_line "$(t other_help)"
        ui_line "$(t other_power)"
        ui_nav
        printf '> '
        c="$(read_choice 3)"
        case "$c" in
            NUM:1)
                # 语言页改的是文件，本进程要立刻重读+换字体，否则看起来没反应
                /usr/local/bin/ai-config.sh --language
                reload_language
                console_font_init 1
                ;;
            NUM:2) /usr/local/bin/ai-help.sh ;;
            NUM:3) power_page ;;
            ESC|EOF|CH:X|CH:x) return 0 ;;
            *) : ;;
        esac
    done
}

# ---------------- 分支 ----------------
handle_choice() {
    local c="$1"
    case "$c" in
        NUM:1)  /usr/local/bin/ai-ssh.sh ;;
        NUM:2)  /usr/local/bin/ai-network.sh --wifi ;;
        # 序号必须与屏幕标签一致：3=密码文件 4=命令行 5=Windows 工具
        # 6=文件浏览 7=备份 8=自检（急救已移到整体配置 A）
        NUM:3)  /usr/local/bin/ai-password.sh --file ;;
        NUM:4)  /usr/local/bin/ai-shell.sh ;;
        NUM:5)  /usr/local/bin/ai-tools.sh --windows ;;
        NUM:6)  /usr/local/bin/ai-tools.sh --browser ;;
        NUM:7)  /usr/local/bin/ai-tools.sh --backup ;;
        NUM:8)  /usr/local/bin/ai-tools.sh --check ;;
        CH:A|CH:a) /usr/local/bin/ai-rescue.sh ;;
        CH:B|CH:b) /usr/local/bin/ai-guided.sh ;;
        # 设置栏只剩 3 个分组入口（危险动作/编辑器都在二级页里）
        CH:C|CH:c) /usr/local/bin/ai-config.sh --menu ;;
        CH:D|CH:d) /usr/local/bin/ai-config.sh --usb ;;
        CH:E|CH:e) other_page ;;
        *) return 0 ;;
    esac
    return 0
}

run_menu() {
    local secs="$AUTO_RESCUE_SECONDS"
    local c=""

    while true; do
        draw_menu "$secs"
        c="$(read_choice 8 "$KEY_FOLLOW" 1)"

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

        case "$c" in
            CH:*) handle_choice "$c" ;;
            NUM:*) handle_choice "$c" ;;
            *)    : ;;
        esac
        # 子界面可能改了语言、也可能在 D 页把配置存到了另一只 U 盘。
        # 回来后必须重新探测位置 + 重读配置，否则 footer 的三态永远停在旧值。
        cfg_refresh_location load 2>/dev/null || true
        reload_language
        console_font_init 1
    done
}

# 让 ESC 在“刚启动”时也能立刻退出，而不是等倒计时
run_menu
