#!/bin/bash
# AI Boot Pro —— 救援启动盘系统
# Copyright (c) 2026 sxzxdpy  <https://github.com/listenablehfcd>
# SPDX-License-Identifier: MIT
# ============================================================
# AI-Boot 5.2 网络模块
#
# 4.0 的 WiFi 页有三个真实缺陷，这里一并修掉：
#   1) 选择分支写成 `case R|r) ... X|x) ... *) 进 SSID 输入`，
#      于是**除 R/X 之外的任何按键**（包括数字、ESC、回车）都会掉进
#      “Enter SSID” 分支 —— 屏幕上明明印着 1. 2. 3. 的编号却选不了。
#   2) 连接成功后是 `press_any_key` 然后脚本结束，回不到“上一级界面”，
#      只能靠再按一次键才退出，观感就是“按了 X 只是刷新了一下”。
#   3) 刷新是 `"$0" --wifi` 递归调用自己，每刷一次多一层进程。
#      现在改成循环，ESC 一下就能干净退出。
#
# 5.3 真机实测（第 3 条）修热点"假成功"：
#   - 没有 dnsmasq / dnsmasq 起不来 → 明确报错并返回 1（原来 `|| true` 恒成功）
#   - hostapd 成功但 DHCP 失败 → 回滚 hostapd，不留"看起来开了其实连不上"
#   - 开热点前精确清掉占用网卡的 wpa_supplicant（不用宽泛 pkill -f）
#   - 新增 ap_t()：AP 调试模式新增/调整的文案。common 的 t() 正被另一个
#     agent 同时修改，为避免互相覆盖先放本文件；key 名与修复设计文档一致，
#     之后可以原样并入 common 的 t() 两张表。
# ============================================================
set -u
source /usr/local/bin/ai-boot-common.sh

MAX_LIST=24          # 一屏最多列多少个
WIFI_LIST=()

wifi_iface() {
    local iface
    for i in /sys/class/net/*; do
        iface="$(basename "$i")"
        [ -d "/sys/class/net/$iface/wireless" ] && { echo "$iface"; return 0; }
    done
    return 1
}

wired_iface() {
    local iface
    for i in /sys/class/net/*; do
        iface="$(basename "$i")"
        [ "$iface" = "lo" ] && continue
        [ ! -d "/sys/class/net/$iface/wireless" ] && { echo "$iface"; return 0; }
    done
    return 1
}

current_ip() {
    ip -4 addr show 2>/dev/null \
        | grep -oE '(inet )[0-9.]+' \
        | awk '{print $2}' \
        | grep -v '^127\.' \
        | head -n 1
}

wait_online() {
    local timeout="${1:-30}" i=0
    while [ "$i" -lt "$timeout" ]; do
        ip route 2>/dev/null | grep -q 'default' && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# ============================================================
# 静态 IP：4.0 的 static_ip/static_mask/static_gateway/static_dns
# 一直是“有键但没人用”，这里让它真的生效。
# ============================================================
net_apply_static() {
    local iface="$1"
    local ipaddr mask gw dns prefix

    ipaddr="$(cfg_get static_ip)"
    mask="$(cfg_get static_mask)"
    gw="$(cfg_get static_gateway)"
    dns="$(cfg_get static_dns)"

    [ -n "$ipaddr" ] || return 1
    prefix="$(netmask_to_prefix "$mask")"

    ip link set "$iface" up 2>/dev/null || true
    ip addr flush dev "$iface" 2>/dev/null || true
    if ! ip addr add "$ipaddr/$prefix" dev "$iface" 2>/dev/null; then
        return 1
    fi
    [ -n "$gw" ] && ip route add default via "$gw" dev "$iface" 2>/dev/null || true
    if [ -n "$dns" ]; then
        rm -f /etc/resolv.conf 2>/dev/null || true
        printf 'nameserver %s\n' "$dns" > /etc/resolv.conf 2>/dev/null || true
    fi
    return 0
}

net_up_wired_dhcp() {
    local iface
    cfg_is_on wired_dhcp || return 1
    iface="$(wired_iface || true)"
    [ -z "$iface" ] && return 1
    ip link set "$iface" up 2>/dev/null || true

    if [ -n "$(cfg_get static_ip)" ]; then
        net_apply_static "$iface" && wait_online 20 && return 0
    fi

    if command -v dhclient >/dev/null 2>&1; then
        dhclient -1 "$iface"
    elif command -v udhcpc >/dev/null 2>&1; then
        udhcpc -i "$iface" -n
    elif command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd -n "$iface"
    else
        return 1
    fi
    wait_online 20
}

dhcp_iface() {
    local iface="$1" rc=1
    if command -v dhclient >/dev/null 2>&1; then
        dhclient -1 "$iface"; rc=$?
    elif command -v udhcpc >/dev/null 2>&1; then
        udhcpc -i "$iface" -n; rc=$?
    elif command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd -n "$iface"; rc=$?
    else
        return 1
    fi
    # 原来这里写死 return 0：DHCP 客户端失败也报成功，
    # 上层就分不清“拿不到地址”和“拿到了”。
    [ "$rc" -eq 0 ] || return 1
    return 0
}

# ============================================================
# 扫描
# ============================================================
wifi_scan_raw() {
    local iface
    iface="$(wifi_iface || true)"
    [ -z "$iface" ] && return 1
    ip link set "$iface" up 2>/dev/null || true
    sleep 1

    if command -v iw >/dev/null 2>&1; then
        iw dev "$iface" scan 2>/dev/null | sed -n 's/^[[:space:]]*SSID:[[:space:]]*//p'
    elif command -v iwlist >/dev/null 2>&1; then
        iwlist "$iface" scan 2>/dev/null | sed -n 's/.*ESSID:"\(.*\)".*/\1/p'
    else
        return 1
    fi
}

# 去重 + 丢掉空 SSID，结果放进 WIFI_LIST
wifi_refresh_list() {
    WIFI_LIST=()
    local s
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        local dup=0
        local x
        for x in "${WIFI_LIST[@]}"; do
            [ "$x" = "$s" ] && { dup=1; break; }
        done
        [ "$dup" = "1" ] && continue
        WIFI_LIST+=("$s")
        [ "${#WIFI_LIST[@]}" -ge "$MAX_LIST" ] && break
    done < <(wifi_scan_raw || true)
    return 0
}

# ============================================================
# 连接
# ============================================================
wifi_connect() {
    local ssid="$1" pass="$2"
    local iface conf
    iface="$(wifi_iface || true)"
    [ -z "$iface" ] && { echo "$(t net_no_wifi)"; return 1; }

    conf="/tmp/wpa.conf"
    # 密码里的 " 和 \ 会破坏 wpa_supplicant 的配置语法，先转义
    local esc
    esc="$(printf '%s' "$pass" | sed 's/\\/\\\\/g; s/"/\\"/g')"

    {
        printf 'ctrl_interface=/run/wpa_supplicant\n'
        printf 'network={\n'
        printf '    ssid="%s"\n' "$(printf '%s' "$ssid" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        if [ -n "$pass" ]; then
            printf '    psk="%s"\n' "$esc"
            printf '    key_mgmt=WPA-PSK\n'
        else
            printf '    key_mgmt=NONE\n'
        fi
        printf '    scan_ssid=1\n'
        printf '}\n'
    } > "$conf" 2>/dev/null || { echo "$(t net_wpa_conf_fail)"; return 1; }

    ip link set "$iface" up 2>/dev/null || true
    # 只清掉本网卡上的旧实例：精确挑 comm=wpa_supplicant 且参数带该网卡的
    # 进程（stop_wpa_on_iface），不用 `pkill -f wpa_supplicant` 那种宽泛匹配。
    stop_wpa_on_iface "$iface"

    if ! command -v wpa_supplicant >/dev/null 2>&1; then
        echo "$(t net_no_wpa)"
        return 1
    fi
    if ! wpa_supplicant -B -i "$iface" -c "$conf" >/dev/null 2>&1; then
        echo "$(t net_wpa_fail)"
        return 1
    fi
    sleep 3

    if [ -n "$(cfg_get static_ip)" ]; then
        net_apply_static "$iface" || true
    else
        dhcp_iface "$iface" || true
    fi
    wait_online 25
}

# 连一个 SSID：问密码 → 连 → 报告 → 停在本页
wifi_connect_flow() {
    local ssid="$1" pass=""
    if [ -n "$ssid" ]; then
        printf 'SSID: %s\n' "$ssid"
        if ! read_secret "$(t net_pass_prompt)"; then
            echo "$(t net_cancelled)"
            sleep 1
            return 1
        fi
        pass="$READ_LINE"
    else
        if ! read_line "$(t net_ssid_prompt)"; then
            echo "$(t net_cancelled)"
            sleep 1
            return 1
        fi
        ssid="$READ_LINE"
        [ -z "$ssid" ] && { echo "$(t net_ssid_empty)"; sleep 1; return 1; }
        if ! read_secret "$(t net_pass_prompt)"; then
            echo "$(t net_cancelled)"
            sleep 1
            return 1
        fi
        pass="$READ_LINE"
    fi

    echo
    echo "$(t net_connecting)$ssid ..."
    if wifi_connect "$ssid" "$pass"; then
        echo "$(t net_connect_ok)"
        echo "$(t net_local_ip)$(current_ip || echo '-')"
    else
        echo "$(t net_connect_fail)"
        echo "$(t net_troubleshoot)"
    fi
    press_any_key || return 0
    return 0
}

# ============================================================
# 热点（AP 调试模式的核心）
# SSID/密码可由配置指定；开热点前会先精确清掉占网卡的 wpa_supplicant。
# ============================================================
gen_hotspot_name() { tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8; }
gen_hotspot_pass() { tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 12; }

hotspot_ssid() {
    local s; s="$(cfg_get hotspot_ssid)"
    [ -n "$s" ] || s="$(gen_hotspot_name)"
    printf '%s\n' "$s"
}
hotspot_pass() {
    local p; p="$(cfg_get hotspot_password)"
    [ -n "$p" ] || p="$(gen_hotspot_pass)"
    printf '%s\n' "$p"
}

# ------------------------------------------------------------
# AP 调试模式的新增/调整文案（中英各一份，key 名与修复设计文档一致）
#
# 为什么不写进 ai-boot-common.sh 的 t()：
#   那个文件此刻正被"设置页重构"的 agent 同时修改，两个 agent 写同一张
#   中英表必然互相覆盖。这里先用一个独立的小表，和 t() 共用同一个
#   AI_BOOT_LANG；等 common 空出来后，把下面这些 key 原样并入 t() 两表即可。
# 字体约束：中文字形只剩 2 个槽位，下面所有中文都只用了已存在的字。
# ------------------------------------------------------------
ap_t() {
    local key="$1"
    if [ "${AI_BOOT_LANG:-en}" = "zh" ]; then
        case "$key" in
            rescue_ap_title)      printf '%s' "最后一步 | 本机开热点" ;;
            rescue_ap_starting)   printf '%s' "正在开启热点，请稍等…" ;;
            rescue_ap_join)       printf '%s' "本机将开启 WiFi 热点。" ;;
            rescue_ap_join2)      printf '%s' "请用另一台设备连接后远程登录。" ;;
            rescue_ap_skip)       printf '%s' "10 秒内按 ESC 可跳过。" ;;
            rescue_ap_skip_to)    printf '%s' "跳过将进入本地指引页。" ;;
            rescue_ap_skip2)      printf '%s' "已跳过热点，进入本地指引页。" ;;
            rescue_ap_countdown)  printf '%s' "自动开启倒计时" ;;
            rescue_ap_to_guide)   printf '%s' "无法开启热点，进入本地指引页。" ;;
            rescue_ap_fail)       printf '%s' "热点启动失败。" ;;
            net_no_hostapd)       printf '%s' "缺少 hostapd 和 nmcli。" ;;
            net_ap_dnsmasq_fail)  printf '%s' "dnsmasq 失败，设备拿不到地址。" ;;
            rescue_s4_title)      printf '%s' "第 4 步 | 本地指引（没网时）" ;;
            rescue_s4_line1)      printf '%s' "前几步都没成功，也没有网络。" ;;
            rescue_s4_line2)      printf '%s' "本页会一直显示，不需要按键。" ;;
            rescue_s4_hint)       printf '%s' "按 5 进命令行，ESC 回主菜单。" ;;
            net_no_dnsmasq)       printf '%s' "缺少 dnsmasq，热点发不了地址。" ;;
            *) : ;;
        esac
        return 0
    fi
    case "$key" in
        rescue_ap_title)      printf '%s' "Step 5 | Last step: open a hotspot on this machine" ;;
        rescue_ap_starting)   printf '%s' "Opening the hotspot, please wait..." ;;
        rescue_ap_join)       printf '%s' "This machine will open a WiFi hotspot." ;;
        rescue_ap_join2)      printf '%s' "Join it from another device, then log in remotely." ;;
        rescue_ap_skip)       printf '%s' "Press ESC within 10 seconds to skip." ;;
        rescue_ap_skip_to)    printf '%s' "Skipping goes to the local guide page." ;;
        rescue_ap_skip2)      printf '%s' "Hotspot skipped. Going to the local guide page." ;;
        rescue_ap_countdown)  printf '%s' "Auto start in" ;;
        rescue_ap_to_guide)   printf '%s' "Cannot start the hotspot. Going to the local guide page." ;;
        rescue_ap_fail)       printf '%s' "Hotspot start failed." ;;
        net_no_hostapd)       printf '%s' "hostapd and nmcli are both missing." ;;
        net_ap_dnsmasq_fail)  printf '%s' "dnsmasq failed: devices cannot get an address." ;;
        rescue_s4_title)      printf '%s' "Step 4 | Local guide (no network)" ;;
        rescue_s4_line1)      printf '%s' "The earlier steps failed and there is no network." ;;
        rescue_s4_line2)      printf '%s' "This page stays; no key is needed." ;;
        rescue_s4_hint)       printf '%s' "Press 5 for a root shell, ESC = back to menu." ;;
        net_no_dnsmasq)       printf '%s' "dnsmasq is missing: the hotspot cannot hand out addresses." ;;
        *) : ;;
    esac
    return 0
}

# 热点固定地址 / 运行文件（/tmp 在 live 系统里可写，重启即清）
HOTSPOT_IP="192.168.66.1"
HOSTAPD_PID="/tmp/aiboot-hostapd.pid"
HOSTAPD_ERR="/tmp/hostapd.err"
DNSMASQ_PID="/tmp/aiboot-dnsmasq.pid"
DNSMASQ_ERR="/tmp/aiboot-dnsmasq.err"

# 热点组件预检：缺哪几项就打印哪几行（每行一条）。
# 返回 0 = 组件齐全；1 = 有缺失（缺失原因已经打印到 stdout）。
hotspot_missing() {
    local missing=0
    if [ -z "$(wifi_iface 2>/dev/null || true)" ]; then
        printf '%s\n' "$(t net_no_wifi)"
        missing=1
    fi
    if ! command -v hostapd >/dev/null 2>&1 && ! command -v nmcli >/dev/null 2>&1; then
        printf '%s\n' "$(ap_t net_no_hostapd)"
        missing=1
    fi
    if ! command -v dnsmasq >/dev/null 2>&1; then
        printf '%s\n' "$(ap_t net_no_dnsmasq)"
        missing=1
    fi
    return "$missing"
}

# 精确清掉占用某张网卡的 wpa_supplicant。
# 不能用 `pkill -f wpa_supplicant`：命令名太常见，会误杀别的网卡/别人
# 正在用的连接。做法：pgrep -a 拿到 pid+完整命令行，comm 必须是
# wpa_supplicant 且参数里带 -i <iface> 才 kill。
stop_wpa_on_iface() {
    local iface="$1" line pid args
    [ -n "$iface" ] || return 0
    if command -v pgrep >/dev/null 2>&1; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            pid="${line%% *}"
            args="${line#* }"
            case " $args " in
                *" -i $iface "*|*" -i$iface "*|*" -i $iface"|*" -i$iface")
                    kill "$pid" 2>/dev/null || true ;;
            esac
        done < <(pgrep -a wpa_supplicant 2>/dev/null || true)
    fi
    sleep 1
    return 0
}

# 只 kill comm 对得上的 pid：pid 文件可能是上一轮留下的，pid 也可能被系统复用，
# 不核对进程名就 kill 有误杀别的进程的风险。
kill_comm() {
    local pid="$1" want="$2" comm
    [ -n "$pid" ] || return 0
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    [ "$comm" = "$want" ] || return 0
    kill "$pid" 2>/dev/null || true
    return 0
}

# 精确停掉本网卡上的旧 dnsmasq（同上，不用宽泛 pkill -f）
stop_dnsmasq_on_iface() {
    local iface="$1" line pid args
    [ -n "$iface" ] || return 0
    if [ -f "$DNSMASQ_PID" ]; then
        kill_comm "$(cat "$DNSMASQ_PID" 2>/dev/null || true)" dnsmasq
        rm -f "$DNSMASQ_PID" 2>/dev/null || true
    fi
    if command -v pgrep >/dev/null 2>&1; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            pid="${line%% *}"
            args="${line#* }"
            case " $args " in
                *"--interface=$iface "*|*"--interface $iface "*)
                    kill "$pid" 2>/dev/null || true ;;
            esac
        done < <(pgrep -a dnsmasq 2>/dev/null || true)
    fi
    sleep 1
    return 0
}

# 停掉我们起的 hostapd（失败回滚 / 重新开启时用）。
# 只认 pid 文件 + argv 里带本模块配置文件的进程，不 pkill -f 误杀别的热点。
stop_hostapd() {
    local pid argv
    if [ -f "$HOSTAPD_PID" ]; then
        kill_comm "$(cat "$HOSTAPD_PID" 2>/dev/null || true)" hostapd
        rm -f "$HOSTAPD_PID" 2>/dev/null || true
    fi
    if command -v pgrep >/dev/null 2>&1; then
        for pid in $(pgrep -x hostapd 2>/dev/null || true); do
            argv="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
            case " $argv " in
                *hostapd.conf*) kill "$pid" 2>/dev/null || true ;;
            esac
        done
    fi
    sleep 1
    return 0
}

# dnsmasq 退出码 0 只代表它认为自己起来了，不代表 DHCP 真的在服务：
# 端口被占 / 绑定失败这类错误发生在 daemon 化之后，光看退出码会漏。
# 这里核对 UDP 67 端口真的在监听（ss → netstat → 没有工具就只能信退出码）。
dhcp_server_listening() {
    if command -v ss >/dev/null 2>&1; then
        ss -lun 2>/dev/null | grep -Eq ':(67)[[:space:]]'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lun 2>/dev/null | grep -Eq ':(67)[[:space:]]'
    else
        return 0
    fi
}

# 热点侧发地址（DHCP）。
# 真机实测第 3 条的根因之一：这里原来是 `dnsmasq ... || true` + `return 0`，
# dnsmasq 根本没起来也显示"热点已启动"，另一台设备连上来拿不到 IP。
# 现在：没有 dnsmasq / 启动失败 / 67 端口没监听 → 都如实返回 1 并说明原因。
start_hotspot_dhcp() {
    local iface="$1" rc=0 i=0
    [ -n "$iface" ] || return 1
    if ! command -v dnsmasq >/dev/null 2>&1; then
        echo "$(ap_t net_no_dnsmasq)"
        return 1
    fi
    stop_dnsmasq_on_iface "$iface"
    rm -f "$DNSMASQ_PID" 2>/dev/null || true
    # --port=0：只发 DHCP，不做 DNS 解析。镜像里没有别的 DNS 服务，关掉 53
    # 端口可以让 dnsmasq 少一个"端口被占就整个退出"的失败面。
    dnsmasq --port=0 --interface="$iface" --bind-interfaces \
            --dhcp-range=192.168.66.10,192.168.66.200,12h \
            --dhcp-leasefile=/tmp/aiboot-dnsmasq.leases \
            --pid-file="$DNSMASQ_PID" \
            >"$DNSMASQ_ERR" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "$(ap_t net_ap_dnsmasq_fail)"
        tail -n 3 "$DNSMASQ_ERR" 2>/dev/null || true
        stop_dnsmasq_on_iface "$iface"
        return 1
    fi
    while [ "$i" -lt 6 ]; do
        dhcp_server_listening && return 0
        sleep 0.5
        i=$((i + 1))
    done
    echo "$(ap_t net_ap_dnsmasq_fail)"
    tail -n 3 "$DNSMASQ_ERR" 2>/dev/null || true
    # 进程可能还在但没在 67 端口服务（端口被占/绑定失败），清掉再回滚
    stop_dnsmasq_on_iface "$iface"
    return 1
}

# 开热点。成功返回 0；失败返回 1 并把真因打在屏幕上（hostapd.err 末 5 行）。
# 顺序：清 wpa_supplicant → 配地址 → 起 hostapd → 起 DHCP；
# DHCP 失败要把 hostapd 回滚掉，不留"看起来开了其实连不上"。
start_pc_hotspot() {
    local ssid="$1" pass="$2"
    local iface hpid
    iface="$(wifi_iface 2>/dev/null || true)"
    if [ -z "$iface" ]; then
        echo "$(t net_no_wifi)"
        return 1
    fi

    # WPA2 要求口令至少 8 位；短口令 hostapd 会直接启动失败
    if [ "${#pass}" -lt 8 ]; then
        echo "$(t net_hotspot_short)$pass"
        return 1
    fi

    # hostapd 与 wpa_supplicant 抢同一张网卡：先把占用它的 wpa_supplicant
    # 精确停掉，否则 hostapd 会因接口还处于站点模式而退出。
    stop_wpa_on_iface "$iface"

    # 先给热点接口一个固定地址，并清掉可能残留的旧地址/旧关联
    ip addr flush dev "$iface" 2>/dev/null || true
    ip addr add "$HOTSPOT_IP/24" dev "$iface" 2>/dev/null || true
    ip link set "$iface" up 2>/dev/null || true

    if command -v hostapd >/dev/null 2>&1; then
        stop_hostapd
        cat > /tmp/hostapd.conf 2>/dev/null <<EOF2
interface=$iface
ssid=$ssid
hw_mode=g
channel=6
wpa=2
wpa_passphrase=$pass
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
driver=nl80211
EOF2
        if ! hostapd -B -P "$HOSTAPD_PID" /tmp/hostapd.conf 2>"$HOSTAPD_ERR"; then
            echo "$(t net_hostapd_fail)"
            tail -n 5 "$HOSTAPD_ERR" 2>/dev/null || true
            stop_hostapd
            return 1
        fi
        sleep 1
        # 优先核对 pid 文件里的进程在跑（最可靠）；没有 pid 文件时退回按进程名查。
        hpid=""
        [ -r "$HOSTAPD_PID" ] && hpid="$(cat "$HOSTAPD_PID" 2>/dev/null || true)"
        if [ -n "$hpid" ] && kill -0 "$hpid" 2>/dev/null; then
            :
        elif command -v pgrep >/dev/null 2>&1 && pgrep -x hostapd >/dev/null 2>&1; then
            :
        else
            echo "$(t net_hostapd_fail)"
            tail -n 5 "$HOSTAPD_ERR" 2>/dev/null || true
            stop_hostapd
            return 1
        fi
        if start_hotspot_dhcp "$iface"; then
            return 0
        fi
        # hostapd 开了但 DHCP 没起来：设备能连上却拿不到 IP、连不上 SSH。
        # 留着只会让人以为"热点可用"，所以回滚 hostapd，如实报失败。
        stop_hostapd
        ip addr flush dev "$iface" 2>/dev/null || true
        return 1
    fi

    if command -v nmcli >/dev/null 2>&1; then
        if ! nmcli dev wifi hotspot ifname "$iface" ssid "$ssid" password "$pass"; then
            echo "$(t net_nmcli_fail)"
            return 1
        fi
        if start_hotspot_dhcp "$iface"; then
            return 0
        fi
        # 同样回滚：不让界面显示"热点已启动"却没有 DHCP
        nmcli connection down Hotspot >/dev/null 2>&1 \
            || nmcli dev disconnect "$iface" >/dev/null 2>&1 || true
        return 1
    fi

    echo "$(ap_t net_no_hostapd)"
    return 1
}

# ============================================================
# WiFi 页面：一直在这里循环，ESC 一下干净返回
# ============================================================
wifi_screen() {
    local c n ip iface

    clear
    echo "$(t net_scanning)"
    wifi_refresh_list

    while true; do
        iface="$(wifi_iface || true)"
        ip="$(current_ip || true)"

        clear
        ui_title "WiFi / Refresh"
        ui_line "$(t net_iface_label)${iface:-$(t net_iface_missing)}"
        ui_line "$(t net_ip_label)${ip:-$(t net_ip_offline)}"
        ui_rule

        local count="${#WIFI_LIST[@]}"
        if [ "$count" -eq 0 ]; then
            ui_line "$(t net_no_networks)"
            ui_line "$(t net_no_networks_hint)"
        else
            local i
            for ((i = 0; i < count; i++)); do
                ui_line "$(printf '%2d. %.56s' "$((i + 1))" "${WIFI_LIST[$i]}")"
            done
        fi
        ui_rule
        ui_line "$(t net_nav_hint)"
        ui_nav
        printf '> '

        c="$(read_choice "$count")"
        case "$c" in
            ESC|EOF|CH:X|CH:x)
                return 0 ;;

            NUM:*)
                n="${c#NUM:}"
                if [ "$n" -ge 1 ] && [ "$n" -le "$count" ]; then
                    wifi_connect_flow "${WIFI_LIST[$((n - 1))]}"
                else
                    echo "$(t net_no_item_a)$n$(t net_no_item_b)"
                    sleep 1
                fi
                ;;

            CH:M|CH:m)
                wifi_connect_flow ""
                ;;

            CH:R|CH:r)
                clear
                echo "$(t net_rescanning)"
                wifi_refresh_list
                ;;

            ENTER|TIMEOUT)
                :
                ;;            # 回车/超时=重绘

            *)
                # 其它键（方向键等）什么都不做，重绘一遍即可。
                # 4.0 就是在这里掉进“Enter SSID”的。
                :
                ;;
        esac
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --wifi) wifi_screen ;;
        --wired) net_up_wired_dhcp && echo "$(t net_wired_ok)" || echo "$(t net_wired_off)" ;;
        *) wifi_screen ;;
    esac
fi
