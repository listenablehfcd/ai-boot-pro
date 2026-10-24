#!/bin/bash
# AI Boot Pro —— 救援启动盘系统
# Copyright (c) 2026 sxzxdpy  <https://github.com/listenablehfcd>
# SPDX-License-Identifier: MIT
# ============================================================
# AI-Boot 5.2 配置模块
#
# 4.0 的实际状况（已逐条复现）：
#   * show_guide_file 调用 confirm()，但这个函数**从未定义**
#     → 一按 B（Guide file config）就 `confirm: command not found`。
#   * 生成的默认配置里**没有 auto_config**，而 4.0 的记忆文档写着
#     “auto_config 总开关：0=任何模式都不用配置；1=启用” → 文档与代码不符。
#   * --auto-config / --auto-save 只是 echo 一句话，没有任何开关作用。
#   * 配置里 20 个键只有 wifi_ssid / wifi_password 被读过，
#     其余（static_*、hotspot_*、ssh_port、ai_user、log_* …）全是死键。
#   * 编辑入口是 nano || vi || cat：Live 里没装编辑器时只会把文件
#     打印出来，你根本改不了，看起来就是“配置文件功能坏了”。
#   * 没有任何地方提示配置到底存不存在、可不可写、重启会不会丢。
#
# 本版本：每个键都真的有人用；没有编辑器也能改；位置与持久性明确告知。
# ============================================================
set -u
source /usr/local/bin/ai-boot-common.sh

# 键 → 说明。顺序与 CFG_KEYS 一致。
cfg_label() {
    case "$1" in
        auto_config)        echo "$(t cfg_lbl_auto_config)" ;;
        auto_save)          echo "$(t cfg_lbl_auto_save)" ;;
        lang)               echo "$(t cfg_lbl_lang)" ;;
        wifi_auto_connect)  echo "$(t cfg_lbl_wifi_auto_connect)" ;;
        wifi_ssid)          echo "$(t cfg_lbl_wifi_ssid)" ;;
        wifi_password)      echo "$(t cfg_lbl_wifi_password)" ;;
        wired_dhcp)         echo "$(t cfg_lbl_wired_dhcp)" ;;
        static_ip)          echo "$(t cfg_lbl_static_ip)" ;;
        static_mask)        echo "$(t cfg_lbl_static_mask)" ;;
        static_gateway)     echo "$(t cfg_lbl_static_gateway)" ;;
        static_dns)         echo "$(t cfg_lbl_static_dns)" ;;
        hotspot_enabled)    echo "$(t cfg_lbl_hotspot_enabled)" ;;
        hotspot_ssid)       echo "$(t cfg_lbl_hotspot_ssid)" ;;
        hotspot_password)   echo "$(t cfg_lbl_hotspot_password)" ;;
        phone_hotspot_ssid)     echo "$(t cfg_lbl_phone_hotspot_ssid)" ;;
        phone_hotspot_password) echo "$(t cfg_lbl_phone_hotspot_password)" ;;
        ai_user)            echo "$(t cfg_lbl_ai_user)" ;;
        ai_done_file)       echo "$(t cfg_lbl_ai_done_file)" ;;
        ai_estop_file)      echo "$(t cfg_lbl_ai_estop_file)" ;;
        ssh_port)           echo "$(t cfg_lbl_ssh_port)" ;;
        ssh_allow_root)     echo "$(t cfg_lbl_ssh_allow_root)" ;;
        log_level)          echo "$(t cfg_lbl_log_level)" ;;
        log_save_usb)       echo "$(t cfg_lbl_log_save_usb)" ;;
        *)                  echo "" ;;
    esac
}

cfg_is_secret() {
    case "$1" in
        wifi_password|hotspot_password|phone_hotspot_password) return 0 ;;
        *) return 1 ;;
    esac
}

cfg_keys_array() { printf '%s\n' $CFG_KEYS; }

cfg_reset_defaults() {
    local k
    for k in "${!CFG_DEFAULT[@]}"; do
        CFG[$k]="${CFG_DEFAULT[$k]}"
    done
    # 同步标记成“已在文件里”，否则 reset 之后 cfg_write 落盘了，
    # 但内存里的 CFG_FROM_FILE 还停留在 reset 之前的状态。
    CFG_FROM_FILE=()
    for k in "${!CFG[@]}"; do
        CFG_FROM_FILE[$k]=1
    done
}

# ============================================================
# 5.0：配置文件位置 / 选盘 / "先问再创建"
# ============================================================
# 为什么要有这一段：
#   4.x 里多个地方会**静默创建**配置文件 —— 用户只是想进去看看，结果 U 盘上
#   多出一个文件；反过来真要创建时又只会用"第一个像 U 盘的分区"，失败就退到
#   内存，用户既看不到有哪些盘、也无法指定。所以改成：**所有写操作前先问一句，
#   并且让用户自己选写到哪个盘**（显示设备名/卷标/剩余空间）。
# ============================================================

cfg_source_line() {
    if [ -f "$CONFIG_FILE" ]; then
        printf '%s' "$(t cfg_source_file)"
    else
        printf '%s' "$(t cfg_source_mem)"
    fi
}

# "配置文件怎么用"页：位置、来源、可写、持久、怎么自动生效、能做什么
cfg_show_howto() {
    clear
    ui_title "$(t cfg_where_title)"
    ui_line "$(t cfg_path)$(ui_cut "$CONFIG_FILE" 24)"
    ui_line "$(t cfg_source)$(cfg_source_line)"
    # 自动扫描到 U 盘上的配置并加载成功时，把真实来源路径也显示出来
    if [ -n "${CFG_LOADED_FROM:-}" ]; then
        ui_line "$(t cfg_loaded_from)$(ui_cut "$CFG_LOADED_FROM" 16)"
    fi
    if [ "$CFG_WRITABLE" = "1" ]; then
        ui_line "$(t cfg_writable_yes)"
    else
        ui_line "$(t cfg_writable_no)"
    fi
    if [ "$CFG_VOLATILE" = "1" ]; then
        ui_line "$(t cfg_persist_no)"
    else
        ui_line "$(t cfg_persist_yes)"
    fi
    ui_rule
    ui_line "$(t cfg_howto_t1)"
    ui_line "$(t cfg_howto_t2)"
    ui_line "$(t cfg_howto_t3)"
    ui_rule
    ui_line "$(t cfg_howto_keys)"
    ui_nav
    # 必须停一下：否则这一页画完立刻返回，调用方马上重画列表，
    # 用户看到的是"按 W 没反应"（5.1 实测抓到的 bug）。
    press_any_key "$(t press_any)" || return 0
    return 0
}

# 选盘：列出所有可写的真实分区（设备名/卷标/剩余/挂载点），外加内存兜底
cfg_pick_disk() {
    local -a devs mps labels frees rms
    local line i c n tries=0
    while IFS='|' read -r dev mp label free rm; do
        [ -n "$mp" ] || continue
        devs+=("$dev"); mps+=("$mp"); labels+=("$label"); frees+=("$free"); rms+=("$rm")
    done < <(cfg_targets)
    n="${#mps[@]}"

    # 真机实测 bug（2026-10-24）：上一步菜单按的"1"+回车里，回车还留在输入缓冲，
    # 选择器一启动立刻读到这个回车 → case 不匹配 → return 1 → 闪一下回主菜单。
    # 修法：① 显示前先把残留输入丢掉；② 给首键 30 秒超时（不再是无限等/被残留带走）；
    #      ③ 任何非数字、非 ESC 的键都重绘本页，只有 ESC 才取消。
    while true; do
        # 丢掉缓冲区里残留的按键（最多 200 个，超时 50ms，不阻塞）
        local _junk
        while IFS= read -r -s -n 1 -t 0.05 _junk 2>/dev/null; do :; done

        clear
        ui_title "$(t cfg_pick_title)"
        if [ "$n" -eq 0 ]; then
            ui_line "$(t cfg_usb_none)"
            ui_rule
            ui_line "$(t cfg_pick_hint)"
            printf '> '
            c="$(read_choice 1 0.5 30)"
            case "$c" in
                ESC|EOF|CH:X|CH:x) return 1 ;;
                *) continue ;;
            esac
        fi
        for ((i = 0; i < n; i++)); do
            ui_line "$(printf '%2d) %-11s %-12s %s %s %s' "$((i + 1))" "${devs[$i]}" "${labels[$i]:-$(t cfg_nolabel)}" "${rms[$i]:+[${rms[$i]}]}" "$(t cfg_free)" "${frees[$i]:--}")"
            ui_line "     $(t cfg_mount)${mps[$i]}"
        done
        ui_line "$(printf '%2d) %s' "$((n + 1))" "$(t cfg_pick_mem)")"
        ui_rule
        ui_line "$(t cfg_pick_hint)"
        printf '> '
        c="$(read_choice "$((n + 1))" 0.5 30)"
        case "$c" in
            NUM:*)
                i="${c#NUM:}"
                if [ "$i" -ge 1 ] && [ "$i" -le "$n" ]; then
                    ai_boot_set_dir "${mps[$((i - 1))]}/AI-Boot"
                    CFG_WRITABLE=1; CFG_VOLATILE=0
                    CFG_STATE="persistent"; CFG_STATE_REASON="manual"
                    export CFG_STATE CFG_STATE_REASON
                    return 0
                elif [ "$i" -eq $((n + 1)) ]; then
                    ai_boot_set_dir "/run/ai-boot"
                    CFG_WRITABLE=1; CFG_VOLATILE=1
                    CFG_STATE="memory"; CFG_STATE_REASON="manual_mem"
                    export CFG_STATE CFG_STATE_REASON
                    return 0
                fi ;;
            ESC|EOF|CH:X|CH:x) return 1 ;;
            TIMEOUT|*) tries=$((tries + 1)); [ "$tries" -ge 999 ] && return 1; continue ;;
        esac
    done
}

# 只读位置的逃逸口（审计修复 C）：把当前内存里的配置另存到用户挑的可写磁盘。
# dd 写入的启动盘是只读 ISO，CONFIG_FILE 写不回去；而审计同时确认本镜像
# 没有 automount —— 用户就算插了第二只 U 盘，以前也无处可选、写不进去。
# 现在公共库的 automount_removable() 会先挂载可移动分区，cfg_pick_disk 才
# 真的能列出那只 U 盘。
# 只**临时**切换 CONFIG_FILE / AI_BOOT_DIR（cfg_write 按当前值写），写完
# 立刻恢复，不把本次会话的全局状态改坏（否则后续编辑会写到别处，很难解释）。
cfg_save_to_writable() {
    local orig_dir="$AI_BOOT_DIR" orig_wr="$CFG_WRITABLE" orig_vol="$CFG_VOLATILE"
    local orig_state="$CFG_STATE" orig_reason="$CFG_STATE_REASON"
    local dest rc=1
    if ! cfg_pick_disk; then
        echo "$(t cfg_pick_cancel)"
        sleep 2
        return 1
    fi
    dest="$CONFIG_FILE"
    CFG_WRITABLE=1
    if cfg_write; then
        echo "$(t cfg_written)$dest"
        log "config saved to writable disk: $dest"
        rc=0
    else
        # 不能假成功：磁盘满 / 中途被拔 / 突然只读，都必须明确说写入失败
        echo "$(t cfg_write_fail)"
        log "config save to $dest FAILED"
    fi
    # 恢复原来的位置与可写状态：这一下只是“另存一份”，不是搬家
    ai_boot_set_dir "$orig_dir"
    CFG_WRITABLE="$orig_wr"
    CFG_VOLATILE="$orig_vol"
    CFG_STATE="$orig_state"; CFG_STATE_REASON="$orig_reason"
    export CFG_STATE CFG_STATE_REASON
    sleep 2
    return "$rc"
}

# ---- 位置三态（持久 / 只读 / 仅内存）如实显示 ----
# 路径一律用 ui_cut 按当前列宽截断：中文只有 38 列，直接拼完整路径会
# 变成“半句+~”，用户以为界面坏了（真机反馈）。
show_location_block() {
    ui_line "$(t cfg_location_label)$(cfg_status_label)"
    ui_line "$(t cfg_path)$(ui_cut "$CONFIG_FILE" 24)"
}

# -------- D. U 盘页：保存到 U 盘 / 选择 U 盘位置 --------
# “保存到 U 盘”是一个明确动作：有可写盘就立即写并显示真实路径；
# 没有可写盘就明说“请接上可写 U 盘”，绝不假装成功（真机第 2/5 条）。
cfg_save_to_usb() {
    local mp dir
    # 当前已经是可写持久位置：直接写回原文件即可
    if [ "$CFG_WRITABLE" = "1" ] && [ "$CFG_VOLATILE" != "1" ]; then
        if cfg_write; then
            echo "$(t cfg_written)$CONFIG_FILE"
            log "config written: $CONFIG_FILE"
            return 0
        fi
        echo "$(t cfg_write_fail)"
        log "config write FAILED: $CONFIG_FILE"
        return 1
    fi
    # 现场插拔后重新扫描（进页面前才插上的 U 盘，这里必须再挂一次）
    command -v cfg_automount >/dev/null 2>&1 && cfg_automount >/dev/null 2>&1 || true
    mp="$(cfg_writable_mount 2>/dev/null || true)"
    if [ -z "$mp" ]; then
        echo "$(t cfg_usb_none)"
        sleep 2
        return 1
    fi
    dir="$mp/AI-Boot"
    mkdir -p "$dir" 2>/dev/null || { echo "$(t cfg_write_fail)"; sleep 2; return 1; }
    ai_boot_set_dir "$dir"
    USB_ROOT="$mp"
    CFG_WRITABLE=1; CFG_VOLATILE=0
    CFG_STATE="persistent"; CFG_STATE_REASON="usb"
    export CFG_STATE CFG_STATE_REASON
    if cfg_write; then
        echo "$(t cfg_written)$CONFIG_FILE"
        log "config written: $CONFIG_FILE"
        sleep 1
        return 0
    fi
    echo "$(t cfg_write_fail)"
    log "config write FAILED: $CONFIG_FILE"
    sleep 2
    return 1
}

# 选择 U 盘位置：选完立刻把当前配置写过去（否则用户以为“选了就存了”）
cfg_choose_location() {
    command -v cfg_automount >/dev/null 2>&1 && cfg_automount >/dev/null 2>&1 || true
    if ! cfg_pick_disk; then
        echo "$(t cfg_pick_cancel)"
        sleep 2
        return 1
    fi
    mkdir -p "$AI_BOOT_DIR" 2>/dev/null || { echo "$(t cfg_create_fail)"; sleep 2; return 1; }
    if cfg_write; then
        echo "$(t cfg_written)$CONFIG_FILE"
        log "config location chosen: $CONFIG_FILE"
        sleep 1
        return 0
    fi
    echo "$(t cfg_write_fail)"
    sleep 2
    return 1
}

usb_menu() {
    local c
    while true; do
        clear
        ui_title "$(t title_usb)"
        show_location_block
        ui_rule
        ui_line "$(t cfg_usb_save)"
        ui_line "$(t cfg_usb_choose)"
        ui_nav
        printf '> '
        c="$(read_choice 2)"
        case "$c" in
            NUM:1) cfg_save_to_usb || true ;;
            NUM:2) cfg_choose_location || true ;;
            ESC|EOF|CH:X|CH:x) return 0 ;;
            *) : ;;
        esac
    done
}

# -------- C. Config 页：查看 / 修改 / 默认值 --------
config_menu() {
    local c
    while true; do
        clear
        ui_title "$(t title_config)"
        show_location_block
        ui_rule
        ui_line "$(t cfg_menu_view)"
        ui_line "$(t cfg_menu_edit)"
        ui_line "$(t cfg_menu_defaults)"
        ui_nav
        printf '> '
        c="$(read_choice 3)"
        case "$c" in
            NUM:1) show_current_config ;;
            NUM:2) config_edit_menu ;;
            NUM:3) config_defaults_menu ;;
            ESC|EOF|CH:X|CH:x) return 0 ;;
            *) : ;;
        esac
    done
}

config_edit_menu() {
    local c
    while true; do
        clear
        ui_title "$(t cfg_edit_title)"
        ui_line "$(t cfg_edit_menu_items)"
        ui_line "$(t cfg_edit_menu_direct)"
        ui_nav
        printf '> '
        c="$(read_choice 2)"
        case "$c" in
            NUM:1) edit_config_screen ;;
            NUM:2) config_edit_direct ;;
            ESC|EOF|CH:X|CH:x) return 0 ;;
            *) : ;;
        esac
    done
}

# 直接开编辑器前必须二次确认：旧版 G 一按就进 nano，普通人退不出来
# （真机第 7 条）。没编辑器时 edit_raw_file 会自动降级到逐项编辑。
config_edit_direct() {
    clear
    ui_title "$(t cfg_edit_menu_direct)"
    ui_line "$(t cfg_direct_confirm)"
    ui_rule
    if ! confirm "$(t cfg_direct_confirm)"; then
        return 0
    fi
    edit_raw_file
}

config_defaults_menu() {
    local c
    while true; do
        clear
        ui_title "$(t cfg_default_title)"
        ui_line "$(t cfg_menu_viewdef)"
        ui_line "$(t cfg_menu_restore)"
        ui_nav
        printf '> '
        c="$(read_choice 2)"
        case "$c" in
            NUM:1) show_default_config ;;
            NUM:2) config_restore_defaults ;;
            ESC|EOF|CH:X|CH:x) return 0 ;;
            *) : ;;
        esac
    done
}

config_restore_defaults() {
    clear
    ui_title "$(t cfg_default_title)"
    ui_line "$(t cfg_reset_confirm2)"
    ui_line "$(t cfg_path)$(ui_cut "$CONFIG_FILE" 20)"
    ui_rule
    if ! confirm "$(t cfg_reset_confirm2)" ; then
        return 0
    fi
    if ! cfg_ensure_file; then
        return 0
    fi
    cfg_reset_defaults
    if cfg_write; then
        echo "$(t cfg_reset_done)"
        log "defaults restored: $CONFIG_FILE"
    else
        echo "$(t cfg_write_fail)"
    fi
    sleep 1
    return 0
}

# 需要写文件时调用：文件不存在就先问用户（并让他选盘）。0=可以写，1=别写
cfg_ensure_file() {
    [ -f "$CONFIG_FILE" ] && return 0

    clear
    ui_title "$(t cfg_create_title)"
    ui_line "$(t cfg_create_ask)"
    ui_line "$(t cfg_path)$CONFIG_FILE"
    ui_rule
    if ! confirm "$(t cfg_create_confirm)"; then
        clear
        ui_line "$(t cfg_create_skip)"
        sleep 2
        return 1
    fi

    # 让用户选写到哪个盘（默认给的是自动探测到的那个，用 X 可以换）
    clear
    ui_title "$(t cfg_pick_title)"
    ui_line "$(t cfg_pick_current)${AI_BOOT_DIR%/AI-Boot}"
    ui_rule
    if confirm "$(t cfg_pick_use_this)"; then
        :
    else
        cfg_pick_disk || { echo "$(t cfg_pick_cancel)"; sleep 2; return 1; }
    fi

    mkdir -p "$AI_BOOT_DIR" 2>/dev/null || {
        echo "$(t cfg_create_fail)"
        sleep 2
        return 1
    }
    return 0
}

# ---------------- 展示用 ----------------
show_where() {
    ui_title "$(t cfg_where_title)"
    ui_line "$(t cfg_path)$(ui_cut "$CONFIG_FILE" 30)"
    if [ "$CFG_WRITABLE" = "1" ]; then
        ui_line "$(t cfg_writable_yes)"
    else
        ui_line "$(t cfg_writable_no)"
    fi
    if [ "$CFG_VOLATILE" = "1" ]; then
        ui_line "$(t cfg_persist_no)"
        ui_line "$(t cfg_persist_reason)"
    else
        ui_line "$(t cfg_persist_yes)"
    fi
    if [ -n "$USB_ROOT" ]; then
        ui_line "$(t cfg_usb_mount)$USB_ROOT"
    fi
    ui_rule
}

show_current_config() {
    local k v line
    clear
    show_where
    ui_line "$(t cfg_source)$(cfg_source_line)"
    ui_line "$(t cfg_current_list)"
    ui_rule
    for k in $CFG_KEYS; do
        v="${CFG[$k]:-}"
        if cfg_is_bool_key "$k"; then
            v="$(cfg_bool_text "$v")"
        elif cfg_is_secret "$k" && [ -n "$v" ]; then
            v="********"
        fi
        line="$(printf '%-18s = %s' "$k" "$(ui_cut "$v" 48)")"
        ui_line "$line"
    done
    ui_rule
    press_any_key "$(t press_any)" || return 0
}

show_default_config() {
    clear
    ui_title "$(t cfg_default_title)"
    ui_line "$(t cfg_default_note)"
    ui_rule
    local k v line
    for k in $CFG_KEYS; do
        v="${CFG_DEFAULT[$k]:-}"
        cfg_is_bool_key "$k" && v="$(cfg_bool_text "$v")"
        line="$(printf '%-18s = %s' "$k" "$(ui_cut "$v" 48)")"
        ui_line "$line"
    done
    ui_rule
    press_any_key "$(t press_any)" || return 0
}

show_guide() {
    clear
    ui_title "$(t cfg_guide_title)"
    ui_line "$(t cfg_guide_s1)"
    ui_line "$(t cfg_guide_s2)"
    ui_line "$(t cfg_guide_s3)"
    ui_line "$(t cfg_guide_s4)"
    ui_line "$(t cfg_guide_s5)"
    ui_rule
    ui_line "$(t cfg_guide_note)"
    ui_rule
    press_any_key "$(t press_any)" || return 0
}

show_guide_file() {
    clear
    ui_title "$(t cfg_guidefile_title)"
    if [ ! -f "$GUIDE_FILE" ]; then
        ui_line "$(t cfg_file_missing)$GUIDE_FILE"
        ui_line "$(t cfg_guide_help1)"
        ui_line "$(t cfg_guide_help2)"
        ui_rule
        press_any_key "$(t press_any)" || return 0
        return 0
    fi
    ui_line "$(t cfg_file_label)$GUIDE_FILE"
    ui_rule
    # 4.0 在这里调用了一个不存在的 confirm()，直接崩。
    if confirm "$(t cfg_guide_read_confirm)"; then
        clear
        cat "$GUIDE_FILE" 2>/dev/null || echo "$(t cfg_read_fail)"
        ui_rule
        press_any_key "$(t press_any)" || return 0
    fi
    return 0
}

# ---------------- 交互式逐项编辑 ----------------
# 不依赖任何外部编辑器，Live 里一定能用。
edit_one_key() {
    local key="$1" v newval label
    clear
    label="$(cfg_label "$key")"
    ui_title "$(t cfg_edit_title) $key"
    ui_line "$(t cfg_desc)$label"

    v="${CFG[$key]:-}"
    if cfg_is_bool_key "$key"; then
        # 布尔键显示成 开/关，0/1 对普通人是天书
        ui_line "$(t cfg_cur)$(cfg_bool_text "$v")"
        ui_line "$(t cfg_toggle_hint)"
    elif cfg_is_secret "$key" && [ -n "$v" ]; then
        ui_line "$(t cfg_cur)********"   # 不再显示密码长度
    else
        ui_line "$(t cfg_cur)${v:-$(t cfg_empty)}"
    fi
    ui_rule
    ui_line "$(t cfg_edit_hint)"
    ui_rule

    if cfg_is_secret "$key"; then
        if ! read_secret "$(t cfg_newval)"; then return 0; fi
    else
        if ! read_line "$(t cfg_newval)"; then return 0; fi
    fi
    newval="$READ_LINE"

    if [ -z "$newval" ]; then
        return 0
    fi
    if [ "$newval" = "-" ]; then
        newval=""
    fi

    # 校验：布尔只收 0/1/开/关，端口 1-65535，日志级别限定取值
    if ! cfg_validate "$key" "$newval"; then
        case "$key" in
            auto_config|auto_save|wifi_auto_connect|wired_dhcp|hotspot_enabled|ssh_allow_root|log_save_usb)
                echo "$(t cfg_invalid_bool)" ;;
            ssh_port)  echo "$(t cfg_invalid_port)" ;;
            log_level) echo "$(t cfg_invalid_level)" ;;
            *)         echo "$(t cfg_save_fail)$key" ;;
        esac
        sleep 2
        return 0
    fi
    newval="$CFG_NEWVAL"

    # 写之前先问：文件不存在时**不静默创建**
    if ! cfg_ensure_file; then
        return 0
    fi

    if cfg_set "$key" "$newval"; then
        if [ "$(cfg_get auto_save)" = "1" ] && [ -f "$CONFIG_FILE" ]; then
            echo "$(t cfg_saved)$key"
            CFG_DIRTY=0
        else
            echo "$key: $(t cfg_saved_mem)"
            CFG_DIRTY=1
        fi
    else
        echo "$(t cfg_save_fail)$key"
    fi
    sleep 1
    return 0
}

edit_config_screen() {
    local keys idx c n k v line count
    mapfile -t keys < <(cfg_keys_array)
    count="${#keys[@]}"

    while true; do
        clear
        show_where
        # 只读位置必须在页面顶部就说清楚“改了也存不上”，否则用户会以为
        # 配置功能坏了（审计修复 C：这里原来只在小字里提一句）。
        if [ "$CFG_WRITABLE" != "1" ]; then
            ui_rule
            ui_line "$(t cfg_ro_title)"
            ui_line "$(t cfg_ro_line)$CONFIG_FILE"
            ui_line "$(t cfg_ro_save)"
            ui_rule
        fi
        ui_line "$(t cfg_edit_list_title)"
        ui_rule
        for ((idx = 0; idx < count; idx++)); do
            k="${keys[$idx]}"
            v="${CFG[$k]:-}"
            if cfg_is_bool_key "$k"; then
                v="$(cfg_bool_text "$v")"
            elif cfg_is_secret "$k" && [ -n "$v" ]; then
                v="********"
            fi
            line="$(printf '%2d. %-17s = %s' "$((idx + 1))" "$k" "$(ui_cut "$v" 44)")"
            ui_line "$line"
        done
        ui_rule
        ui_line "$(t cfg_edit_keys)"
        ui_nav
        printf '> '

        c="$(read_choice "$count")"
        case "$c" in
            ESC|EOF|CH:X|CH:x)
                # 有未保存改动就先提醒，否则用户以为已经存上了
                if [ "${CFG_DIRTY:-0}" = "1" ]; then
                    ui_rule
                    ui_line "$(t cfg_unsaved_warn)"
                    ui_line "$(t cfg_unsaved_write)"
                    ui_line "$(t cfg_unsaved_drop)"
                    if confirm "$(t cfg_unsaved_confirm)"; then
                        return 0
                    fi
                    continue
                fi
                return 0 ;;
            NUM:*)
                n="${c#NUM:}"
                if [ "$n" -ge 1 ] && [ "$n" -le "$count" ]; then
                    edit_one_key "${keys[$((n - 1))]}"
                else
                    echo "$(t cfg_no_item_a)$n$(t cfg_no_item_b)"
                    sleep 1
                fi
                ;;
            CH:W|CH:w)
                cfg_show_howto ;;
            CH:O|CH:o)
                # 只读位置的逃逸口：把内存里的配置另存到可写磁盘（修复 C）。
                # 可写时不需要它 —— 按 S 就是直接写回原文件。
                if [ "$CFG_WRITABLE" != "1" ]; then
                    cfg_save_to_writable || true
                fi
                ;;
            CH:S|CH:s)
                if ! cfg_ensure_file; then
                    sleep 1
                    continue
                fi
                if cfg_write; then
                    CFG_DIRTY=0
                    echo "$(t cfg_written)$CONFIG_FILE"
                    # log() 原来只被 die() 调用，而 die() 全项目零调用点 ——
                    # 日志文件永远不生成、监视页 L 永远是"日志还不存在"、
                    # log_level/log_save_usb 是死键。这里接通它。
                    log "config written: $CONFIG_FILE"
                else
                    echo "$(t cfg_write_fail)"
                    log "config write FAILED: $CONFIG_FILE"
                fi
                sleep 1
                ;;
            CH:R|CH:r)
                if [ "${CFG_DIRTY:-0}" = "1" ] && ! confirm "$(t cfg_reload_confirm)"; then
                    continue
                fi
                cfg_load
                CFG_DIRTY=0
                echo "$(t cfg_reloaded)"
                sleep 1
                ;;
            CH:D|CH:d)
                # 恢复默认会**覆盖整个文件**，必须说清后果；而且要用户确认位置
                if confirm "$(t cfg_reset_confirm2)$CONFIG_FILE"; then
                    if cfg_ensure_file; then
                        cfg_reset_defaults
                        cfg_write || true
                        CFG_DIRTY=0
                        echo "$(t cfg_reset_done)"
                        sleep 1
                    fi
                fi
                ;;
            *)
                : ;;
        esac
    done
}

# ---------------- 原始文件编辑 ----------------
edit_raw_file() {
    local ed="" cand c
    clear
    # 只读位置就别打开了：用户改完存不上，等于白干（审计已列）
    if [ "$CFG_WRITABLE" != "1" ]; then
        ui_title "$(t cfg_ro_title)"
        ui_line "$(t cfg_ro_line)$CONFIG_FILE"
        # 但只读也不是死路：O = 把内存里的配置另存到可写磁盘（审计修复 C）。
        # 这正是 dd 启动盘 + 第二只 U 盘的用法：没有这一步，配置永远存不下来。
        ui_line "$(t cfg_ro_save)"
        ui_rule
        printf '> '
        c="$(read_choice 1)"
        case "$c" in
            CH:O|CH:o) cfg_save_to_writable || true ;;
            *) : ;;
        esac
        return 0
    fi
    # 文件不存在时**先问再创建**，不再静默建一个出来
    if ! cfg_ensure_file; then
        return 0
    fi

    # busybox 的 vi 是**子命令**，不能塞进一个变量再当命令名执行：
    # 原来 ed="busybox vi" 之后 `"$ed" "$CONFIG_FILE"` 会去找一个名为
    # "busybox vi" 的程序，必然 127。用一个哨兵值单独分支。
    ed=""
    for cand in nano vim vi; do
        if command -v "$cand" >/dev/null 2>&1; then
            ed="$cand"
            break
        fi
    done
    if [ -z "$ed" ] && command -v busybox >/dev/null 2>&1; then
        ed="__busybox_vi__"
    fi

    if [ -z "$ed" ]; then
        ui_title "$(t cfg_no_editor_title)"
        ui_line "$(t cfg_no_editor_l1)"
        ui_line "$(t cfg_no_editor_l2)"
        ui_rule
        press_any_key "$(t press_any)" || return 0
        edit_config_screen
        return 0
    fi

    local edname="$ed" edrc=0
    [ "$ed" = "__busybox_vi__" ] && edname="busybox vi"
    echo "$(t cfg_open_a)$edname$(t cfg_open_b)$CONFIG_FILE"
    echo "$(t cfg_editor_hint)"
    # 不熟悉 vi 的人会困在里面（ESC 不会返回菜单），所以把按键直接打出来
    case "$ed" in
        nano) echo "$(t cfg_save_nano)" ;;
        *)    echo "$(t cfg_save_vi)" ;;
    esac
    if [ "$ed" = "__busybox_vi__" ]; then
        busybox vi "$CONFIG_FILE" || edrc=1
    else
        "$ed" "$CONFIG_FILE" 2>/dev/null || edrc=1
    fi
    if [ "$edrc" != "0" ]; then
        echo
        echo "$edname $(t cfg_editor_fail)"
        press_any_key "$(t press_any)" || return 0
        edit_config_screen
        return 0
    fi
    # 改完重新读一遍，避免内存里还是旧值
    cfg_load
}

# ---------------- 总开关 ----------------
toggle_key() {
    # 4.x 是"按一下就取反"：用户只想看一眼，结果把急救总开关改了；
    # 而且屏幕只给 0/1，没人知道哪个是开。5.0 改成：先显示当前状态（开/关），
    # 再让用户明确按 1 或 0。
    local key="$1" name="$2" cur c v
    cur="$(cfg_get "$key")"
    clear
    ui_title "$name"
    ui_line "$(t cfg_cur)$(cfg_bool_text "$cur")"
    ui_line "$(t cfg_toggle_hint)"
    ui_rule
    c="$(read_choice 2)"
    case "$c" in
        NUM:1|CH:1) v=1 ;;
        NUM:0|CH:0) v=0 ;;
        *)    return 0 ;;
    esac
    if [ "$v" = "$cur" ]; then
        echo "$(t cfg_toggle_same)"
        sleep 1
        return 0
    fi
    if ! cfg_ensure_file; then
        return 0
    fi
    if cfg_set "$key" "$v"; then
        ui_line "$key = $(cfg_bool_text "$v") $(t cfg_toggle_saved)"
    else
        ui_line "$key = $(cfg_bool_text "$v") $(t cfg_toggle_mem)"
    fi
    ui_rule
    press_any_key "$(t press_any)" || return 0
}

switch_language() {
    local c
    clear
    ui_title "$(t cfg_lang_title)"
    ui_line "$(t cfg_cur)$AI_BOOT_LANG"
    ui_rule
    ui_line "1. English"
    ui_line "$(t cfg_lang_zh)"
    ui_nav
    printf '> '
    c="$(read_choice 2)"
    case "$c" in
        NUM:1)
            set_language en
            echo "$(t cfg_switched_en)"
            sleep 1
            ;;
        NUM:2)
            set_language zh
            echo "$(t cfg_switched_zh)"
            sleep 2
            ;;
        *)
            return 0
            ;;
    esac
}

# ---------------- 入口 ----------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        # 旧 CLI 参数保留不删（脚本/帮助可能还在用）
        --guide)        show_guide ;;
        --guide-file)   show_guide_file ;;
        --auto-config)  toggle_key auto_config "$(t cfg_name_autocfg)" ;;
        --auto-save)    toggle_key auto_save "$(t cfg_name_autosave)" ;;
        --current)      show_current_config ;;
        --default)      show_default_config ;;
        --usb-file)     edit_raw_file ;;
        --edit)         edit_config_screen ;;
        --language)     switch_language ;;
        # 新设置页：C. Config / D. USB
        --menu)         config_menu ;;
        --usb)          usb_menu ;;
        *)              show_current_config ;;
    esac
fi
