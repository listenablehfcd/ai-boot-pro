#!/bin/bash
# AI-Boot 5.2 命令行
#   ESC 在这里没有意义（你要的就是一个真 shell），退出 shell 即回到主菜单。
set -u
source /usr/local/bin/ai-boot-common.sh

clear
ui_title "$(t shell_title)"
ui_line "$(t shell_text)"
ui_rule
echo
/bin/bash -l
echo
echo "$(t shell_exit)"
sleep 1
