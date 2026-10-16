#!/bin/bash
# AI Boot Pro —— 救援启动盘系统
# Copyright (c) 2026 sxzxdpy  <https://github.com/listenablehfcd>
# SPDX-License-Identifier: MIT
# AI-Boot 5.2 帮助
set -u
source /usr/local/bin/ai-boot-common.sh

show_help() {
    clear
    ui_title "$(t help_title) $AI_BOOT_VERSION"
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
    ui_blank
    ui_line "$(t help_cfg)$CONFIG_FILE"
    ui_rule
    ui_line "$(t help_note1)"
    ui_line "$(t help_note2)"
    ui_rule
    press_any_key "$(t press_any)" || true
}

show_help
