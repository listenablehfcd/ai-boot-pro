#!/bin/bash
# AI Boot Pro —— 救援启动盘系统
# Copyright (c) 2026 sxzxdpy  <https://github.com/listenablehfcd>
# SPDX-License-Identifier: MIT
# ============================================================
# AI-Boot 5.2 命令行
#   ESC 在这里没有意义（你要的就是一个真 shell），退出 shell 即回到主菜单。
#
# 5.3 真机实测（第 4 条）"进调试 shell 后没有 /mnt"：
#   已核实：镜像 rootfs 里 /mnt /media /run /tmp 都在；initramfs 里**只有
#   /run** —— 用户当时其实在 initramfs/调试环境，所以没有 /mnt。
#   现在进 shell 前做两件事：
#     1) mkdir -p /mnt /media /run /tmp；建不出来的逐条 WARNING
#     2) 首屏用纯 ASCII 说明"你在哪"：内核 / 根挂载来源 / systemd 是否在跑 /
#        目录检查结果 / lsblk 与 mount 的提示
#   为什么这段不翻译成中文：英文模式没有中文字形，而且 shell 里中文最容易
#   乱码；这段是给现场用户和远程 AI 看的环境信息，刻意保持 ASCII。
#
#   本文件同时被 ai-monitor.sh source（监视页按 C 进 root shell 时复用同一套
#   环境检查），所以这里只定义函数，真正的动作放在末尾 BASH_SOURCE 守卫里。
# ============================================================
set -u
# 被 source 时 ai-boot-common.sh 通常已经加载；直接执行本文件时才需要自己 source。
if ! command -v ui_line >/dev/null 2>&1; then
    source /usr/local/bin/ai-boot-common.sh
fi

# 进 shell 前的环境检查 + 纯 ASCII 环境说明（幂等，可以重复调用）
ai_shell_env_prepare() {
    local d missing="" kernel root_src root_fstype sysd
    mkdir -p /mnt /media /run /tmp 2>/dev/null || true
    for d in /mnt /media /run /tmp; do
        [ -d "$d" ] || missing="$missing $d"
    done
    kernel="$(uname -r 2>/dev/null || echo unknown)"
    root_fstype="$(awk '$2 == "/" { print $3; exit }' /proc/mounts 2>/dev/null)"
    root_src="$(awk '$2 == "/" { print $1; exit }' /proc/mounts 2>/dev/null)"
    [ -n "$root_src" ] || root_src="unknown"
    if [ -n "$root_fstype" ] && [ "$root_fstype" != "$root_src" ]; then
        root_src="$root_src ($root_fstype)"
    fi
    if [ -d /run/systemd/system ]; then
        sysd="running  (= a full live system)"
    else
        sysd="NOT running -> you may be in initramfs or a chroot; /mnt may be absent"
    fi
    echo "------------------------------------------------------------"
    echo "ENV    : AI-Boot live system"
    echo "  kernel : $kernel"
    echo "  rootfs : $root_src"
    echo "  systemd: $sysd"
    if [ -n "$missing" ]; then
        echo "  dirs   : WARNING: cannot create:$missing"
    else
        echo "  dirs   : /mnt /media /run /tmp present (created if needed)"
    fi
    echo "  hint   : lsblk ; mkdir -p /mnt/win ; mount -o ro /dev/sdXN /mnt/win"
    echo "------------------------------------------------------------"
    return 0
}

run_local_shell() {
    clear
    ui_title "$(t shell_title)"
    ui_line "$(t shell_text)"
    ui_rule
    echo
    ai_shell_env_prepare
    echo
    /bin/bash -l
    echo
    echo "$(t shell_exit)"
    sleep 1
}

# 只在被直接执行时跑；被 ai-monitor.sh source 时只提供上面的函数
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_local_shell
fi
