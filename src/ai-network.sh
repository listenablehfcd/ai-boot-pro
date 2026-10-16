#!/bin/bash
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
    # 只清掉本网卡上的旧实例，不要 pkill 掉别人的
    pkill -f "wpa_supplicant.*-i *$iface" 2>/dev/null || true
    sleep 1

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
# 热点（保留 4.0 能力，SSID/密码可由配置指定）
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

# 热点侧发地址：有 dnsmasq 就用它，没有就明确说清"设备要手动配 IP"。
# 4.1 从头到尾没给热点接口配过地址，设备就算连上也拿不到 IP、连不上 SSH。
start_hotspot_dhcp() {
    local iface="$1"
    if command -v dnsmasq >/dev/null 2>&1; then
        command -v pkill >/dev/null 2>&1 && pkill -f "dnsmasq.*$iface" 2>/dev/null || true
        dnsmasq --interface="$iface" --bind-interfaces \
                --dhcp-range=192.168.66.10,192.168.66.200,12h \
                >/dev/null 2>&1 || true
    else
        echo "$(t net_no_dnsmasq)"
    fi
    return 0
}

start_pc_hotspot() {
    local ssid="$1" pass="$2"
    local iface
    iface="$(wifi_iface || true)"
    [ -z "$iface" ] && return 1

    # WPA2 要求口令至少 8 位；短口令 hostapd 会直接启动失败
    if [ "${#pass}" -lt 8 ]; then
        echo "$(t net_hotspot_short)$pass"
        return 1
    fi

    # 先给热点接口一个固定地址，并清掉可能残留的旧地址/旧关联
    ip addr flush dev "$iface" 2>/dev/null || true
    ip addr add 192.168.66.1/24 dev "$iface" 2>/dev/null || true
    ip link set "$iface" up 2>/dev/null || true

    if command -v hostapd >/dev/null 2>&1; then
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
        command -v pkill >/dev/null 2>&1 && pkill -f "hostapd.*hostapd.conf" 2>/dev/null || true
        # 关键修复：4.1 完全不看退出码，hostapd 起不来也照样报"热点已启动"。
        if hostapd -B /tmp/hostapd.conf 2>/tmp/hostapd.err; then
            sleep 1
            if command -v pgrep >/dev/null 2>&1; then
                if pgrep -f "hostapd.*hostapd.conf" >/dev/null 2>&1; then
                    start_hotspot_dhcp "$iface"
                    return 0
                fi
            else
                # 没有 procps 时无法核对进程，只能以退出码为准
                start_hotspot_dhcp "$iface"
                return 0
            fi
        fi
        echo "$(t net_hostapd_fail)"
        tail -n 5 /tmp/hostapd.err 2>/dev/null || true
        return 1
    fi

    if command -v nmcli >/dev/null 2>&1; then
        if nmcli dev wifi hotspot ifname "$iface" ssid "$ssid" password "$pass"; then
            start_hotspot_dhcp "$iface"
            return 0
        fi
        echo "$(t net_nmcli_fail)"
        return 1
    fi
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
