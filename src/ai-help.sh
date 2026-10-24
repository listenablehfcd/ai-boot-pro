#!/bin/bash
# AI Boot Pro —— 救援启动盘系统
# Copyright (c) 2026 sxzxdpy  <https://github.com/listenablehfcd>
# SPDX-License-Identifier: MIT
# AI-Boot 5.2 帮助
#
# 帮助页必须与实际菜单一一对应（真机反馈：旧帮助写着不存在的自检页码，
# 菜单却只有 8 项）。菜单改动时，这里和 t() 里的 help_* 文案要一起改。
set -u
source /usr/local/bin/ai-boot-common.sh

show_help() {
    clear
    ui_title "$(t help_title) $AI_BOOT_VERSION"
    # 第一行先给不会用的人一条出路：按 A 进急救（全自动）
    ui_line "$(t help_first)"
    ui_rule
    ui_line "$(t help_keys_title)"
    ui_rule
    ui_line "$(t help_k1)"
    ui_line "$(t help_k2)"
    ui_line "$(t help_k3)"
    ui_line "$(t help_k4)"
    ui_line "$(t help_k5)"
    ui_blank
    ui_line "$(t help_menu_title)"
    ui_rule
    ui_line "$(t help_m1)"
    ui_line "$(t help_m2)"
    ui_line "$(t help_m3)"
    ui_line "$(t help_m4)"
    ui_line "$(t help_m5)"
    ui_line "$(t help_m6)"
    ui_blank
    # 配置路径可能很长：按列宽截断，避免把边框撑破
    ui_line "$(t help_cfg)$(ui_cut "$CONFIG_FILE" 22)"
    ui_rule
    ui_line "$(t help_note1)"
    ui_line "$(t help_note2)"
    ui_rule
    press_any_key "$(t press_any)" || true
}

show_help
