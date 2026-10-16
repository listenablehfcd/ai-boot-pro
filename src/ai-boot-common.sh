#!/bin/bash
# ============================================================
# AI-Boot 5.2 公共库
#   - 统一按键层 read_key / read_choice  （ESC 永远是“返回上一级”）
#   - 统一界面框架 ui_*                  （对齐的 ASCII 边框）
#   - 配置文件读写 cfg_*                  （键=值，真正被各个模块使用）
# 被其它脚本 source。不要直接执行。
# ============================================================
set -u

# ---- 重复 source 保护 ----
# 没有这个守卫的话，ai-rescue.sh 一条链上会把本文件执行 5 次
# （自己 + network + password + 被调用的 shell/monitor 模块），
# 于是 init_paths / cfg_load / find_usb_root 白跑 5 遍，
# “配置临时放在内存里”的警告横幅也重复印 5 次（已实测）。
# find_usb_root 里还有递归 find，在真机上这 5 遍是实打实的耗时。
if [ -n "${AI_BOOT_COMMON_LOADED:-}" ]; then
    return 0
fi
AI_BOOT_COMMON_LOADED=1

AI_BOOT_VERSION="Pro"

# ★ 必须显式设置 UTF-8 locale ★
# systemd 服务不设 locale 时，bash 的 ${#var} 按**字节**计数（"中文字" = 9 而不是 3），
# 于是所有含中文的行都会短 k 列、右边框参差、表格错位，而且只在中文模式下暴露。
# C.UTF-8 在 Debian 与 Ubuntu 都是内置的，无需 locale-gen。
if [ -z "${AI_BOOT_LOCALE_SET:-}" ]; then
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8
    AI_BOOT_LOCALE_SET=1
    export AI_BOOT_LOCALE_SET
fi
AI_BOOT_DATE="2026-10-04"
AI_BOOT_COPYRIGHT="(c) sxzxdpy"

# ============================================================
# 一、按键层
# ============================================================
KEY_ESC=$'\033'
KEY_TAB=$'\t'
KEY_BS=$'\177'
KEY_BS2=$'\010'
KEY_FOLLOW=0.5     # 多位数字之间的等待时间（秒）

# 读一个按键，规范化后打印 token（调用方用 $() 取）：
#   ESC / UP / DOWN / LEFT / RIGHT / HOME / END / SEQ
#   ENTER / TAB / BACKSPACE
#   TIMEOUT（$1 秒内无输入）/ EOF
#   其它单字符原样输出
#
# 为什么要处理 ESC 后面的序列：方向键是 ESC [ A，Home 是 ESC [ 1 ~，
# 如果只读一个字节，ESC 会被当成“返回”，剩下的 `[` `1` `~` 会被当成三次按键。
#
# 关于“ESC 后面紧跟另一个键”：这种输入没法回退，只能吞掉那个字节。
# 这里刻意让 ESC 优先胜出（返回 ESC 而不是那个字节）——用户按 ESC 就是要返回，
# 宁可丢一次按键，也不能把 ESC 丢掉后误触发别的动作。
read_key() {
    local tmo="${1:-}"
    local k="" rc=0 s1="" s2=""

    # 上次探测转义序列时如果多吃了一个字节，这里先取回来。
    # 见下面 key_pb_* 的说明：不这样做的话，连按两下 ESC 只会生效一下。
    if key_pb_get; then
        k="$KEY_PB_BYTE"
    else
        if [ -n "$tmo" ]; then
            IFS= read -r -s -n 1 -t "$tmo" k
            rc=$?
        else
            IFS= read -r -s -n 1 k
            rc=$?
        fi

        # 这里必须区分「超时」和「EOF」，不能一律当超时：
        #   0      读到了
        #   1      EOF（stdin 关了 / 被管道驱动 / 控制台消失）
        #   >128   超时（这段时间内没有输入）
        # 混为一谈的后果实测过：主菜单在 stdin 关闭后会满速重绘死循环
        # （25 秒重绘 125 帧），而且 run_menu 里的 EOF 分支永远走不到。
        if [ "$rc" -gt 128 ]; then
            printf 'TIMEOUT\n'; return 1
        fi
        if [ "$rc" -ne 0 ]; then
            printf 'EOF\n'; return 1
        fi
    fi

    if [ "$k" = "$KEY_ESC" ]; then
        if IFS= read -r -s -n 1 -t 0.05 s1; then
            case "$s1" in
                '['|'O')
                    # 已经是转义序列，继续吃到终结符（字母或 ~）
                    while IFS= read -r -s -n 1 -t 0.05 s2; do
                        case "$s2" in
                            A)      printf 'UP\n'    ; return 0 ;;
                            B)      printf 'DOWN\n'  ; return 0 ;;
                            C)      printf 'RIGHT\n' ; return 0 ;;
                            D)      printf 'LEFT\n'  ; return 0 ;;
                            H)      printf 'HOME\n'  ; return 0 ;;
                            F)      printf 'END\n'   ; return 0 ;;
                            [0-9\;]) : ;;      # 参数与修饰键，继续吃
                            *)      printf 'SEQ\n'   ; return 0 ;;
                        esac
                    done
                    printf 'SEQ\n'
                    return 0 ;;
                *)
                    # ESC 后面跟的不是 '[' 或 'O'，说明用户按的是「ESC 然后
                    # 马上又按了别的键」（或者 Alt+键）。原来这个字节是直接
                    # 丢掉的，后果很实在：**连按两下 ESC 只会生效一下**，
                    # 用户看到的就是「按一下没反应，得再按一下」。
                    # 现在把它存进回退缓冲，下一次 read_key 先取它。
                    key_pb_put "$s1"
                    ;;
            esac
        fi
        printf 'ESC\n'
        return 0
    fi

    case "$k" in
        '')                   printf 'ENTER\n' ;;
        "$KEY_TAB")           printf 'TAB\n' ;;
        "$KEY_BS"|"$KEY_BS2") printf 'BACKSPACE\n' ;;
        *)                    printf '%s\n' "$k" ;;
    esac
    return 0
}

# 统一“选择”读取，打印 token：
#   ESC / ENTER / TIMEOUT / EOF / NUM:<数字> / CH:<字符>
#
# $1 = 最大序号（可选）。给了它就能做到“一位数按下即生效”：
#      列表只有 9 项时按 3 → 30 > 9，不可能还有第二位，立刻返回 NUM:3；
#      列表有 12 项时按 1 → 10 <= 12，可能还有第二位，再等 0.5 秒。
# $2 = 多位数之间的等待秒数，默认 0.5
# $3 = 第一次读取的超时秒数（可选）。给了它就变成非阻塞，超时返回 TIMEOUT，
#      菜单的倒计时就是靠这个实现的。
read_choice() {
    local max="${1:-0}"
    local follow="${2:-$KEY_FOLLOW}"
    local tmo="${3:-}"
    local first k n

    if [ -n "$tmo" ]; then
        first="$(read_key "$tmo")"
    else
        first="$(read_key)"
    fi

    case "$first" in
        ESC)         printf 'ESC\n'   ; return 0 ;;
        ENTER)       printf 'ENTER\n' ; return 0 ;;
        TIMEOUT)     printf 'TIMEOUT\n' ; return 0 ;;
        # 输入流结束（例如被 pipe 驱动）单独报出来，由各界面自己决定怎么退，
        # 免得“EOF → 当 ESC → 又回到上一级 → 又 EOF”来回空转。
        EOF)         printf 'EOF\n'   ; return 0 ;;
        [0-9])
            n="$first"
            while :; do
                [ "$n" = "0" ] && break
                if [ "$max" -gt 0 ] && [ $((n * 10)) -gt "$max" ]; then break; fi
                k="$(read_key "$follow")"
                case "$k" in
                    [0-9]) n="$n$k" ;;
                    ESC)   printf 'ESC\n'; return 0 ;;
                    *)     break ;;
                esac
            done
            printf 'NUM:%s\n' "$((n + 0))"
            return 0 ;;
        *) printf 'CH:%s\n' "$first"; return 0 ;;
    esac
}

# 读一整行文本，但按 ESC 可以取消。
# $1 = 提示语
# 成功时打印输入内容并返回 0；按 ESC 返回 1；按回车返回 0（空串）
# 结果同时放在 READ_LINE 里，方便调用方区分“空回车”和“ESC”
READ_LINE=""
read_line() {
    local prompt="${1:-}"
    local k tail
    READ_LINE=""
    [ -n "$prompt" ] && printf '%s' "$prompt"

    k="$(read_key)"
    case "$k" in
        ESC)
            printf '\n'
            return 1 ;;
        ENTER)
            printf '\n'
            READ_LINE=""
            return 0 ;;
        TIMEOUT|EOF)
            printf '\n'
            return 1 ;;
    esac

    # read_key 内部用 read -s（不回显），所以第一个字符用户看不见 —— 会以为
    # 没反应而重敲，得到 "aai" 这种被污染的值。这里补一次回显。
    case "$k" in
        TAB|BACKSPACE|SEQ|UP|DOWN|LEFT|RIGHT|HOME|END|ENTER|ESC|TIMEOUT|EOF) : ;;
        *) printf '%s' "$k" ;;
    esac

    tail=""
    IFS= read -r tail || tail=""
    READ_LINE="$k$tail"
    return 0
}

# 读一行不显示内容的输入（密码用）。第一个字符用 read_key 读，
# 所以 ESC 依然是“按一下即取消”，后面的内容不回显。
READ_LINE=""
read_secret() {
    local prompt="${1:-}"
    local k tail
    READ_LINE=""
    [ -n "$prompt" ] && printf '%s' "$prompt"

    k="$(read_key)"
    case "$k" in
        ESC)         printf '\n'; return 1 ;;
        ENTER)       printf '\n'; READ_LINE=""; return 0 ;;
        TIMEOUT|EOF) printf '\n'; return 1 ;;
    esac

    printf '*'
    tail=""
    IFS= read -r -s tail || tail=""
    printf '\n'
    READ_LINE="$k$tail"
    return 0
}

# 打印提示并等任意键。按 ESC 返回 1（调用方据此“返回上一级”）
press_any_key() {
    local msg="${1:-$(t press_any)}"
    echo
    echo "$msg"
    local k
    k="$(read_key)"
    case "$k" in
        ESC) return 1 ;;
        *)   return 0 ;;
    esac
}

# 等 $1 秒，或按任意键提前结束；**总是返回 0**。
# 急救模式可能完全没有键盘（只有屏幕），任何"请按键继续"都必须有超时兜底，
# 否则流程会永远停在那儿 —— 这是 4.x 里 press_any_key 造成的一个隐藏死路。
ui_wait_key() {
    local secs="${1:-5}" msg="${2:-}" i=0 c
    [ -n "$msg" ] && echo "$msg"
    while [ "$i" -lt "$secs" ]; do
        c="$(read_choice 0 1 1)"
        case "$c" in
            TIMEOUT|'') : ;;
            *) return 0 ;;
        esac
        i=$((i + 1))
    done
    return 0
}

# 可被 ESC 打断的等待。返回 1 表示用户按了 ESC（用于“中止当前流程回上一级”）
sleep_int() {
    local secs="$1" msg="${2:-}" i=0 c
    while [ "$i" -lt "$secs" ]; do
        if [ -n "$msg" ]; then
            printf '\r%s %3d s %s' "$msg" "$((secs - i))" "$(t common_esc_abort)"
        fi
        c="$(read_choice 0 0.5 1)"
        case "$c" in
            ESC|X|x)  [ -n "$msg" ] && printf '\n'; return 1 ;;
            # 控制台没了就别再空等：原来是只认 ESC，stdin 一关就会把
            # 180 秒的倒计时一秒一秒空跑完。
            EOF)  [ -n "$msg" ] && printf '\n'; return 1 ;;
        esac
        i=$((i + 1))
    done
    [ -n "$msg" ] && printf '\n'
    return 0
}

# Y/N 确认。按 ESC 等同 N。
# 注意：4.0 里这个方法被调用但从未定义，是 `--guide-file` 直接崩掉的原因。
confirm() {
    local prompt="${1:-$(t common_confirm_default)}"
    local k
    while true; do
        printf '%s [Y/N] ' "$prompt"
        k="$(read_key)"
        case "$k" in
            Y|y) echo "Y"; return 0 ;;
            N|n) echo "N"; return 1 ;;
            ESC|X|x|EOF) echo "$(t common_cancelled)"; return 1 ;;
            TIMEOUT) echo "$(t common_timeout_cancel)"; return 1 ;;
            *)   echo "$(t common_yn_hint)" ;;
        esac
    done
}

# ============================================================
# 二、界面框架
# ============================================================
# 用 printf %-72s 补空格是按**字节**补的，中文一个字 3 字节，
# 补出来的行在终端上会短一截，右边框会歪。所以这里按“显示宽度”补：
#   ASCII 算 1 列，非 ASCII（中文等）算 2 列。
# 先探测一次当前的 bash 是按字符还是按字节数 ${#var}，两种都兜住。
# ── 界面宽度按字体算（5.0）──────────────────────────────────────────
# 英文用 8×16 字体（每格 8px），中文用 16×16 字体（每格 16px）。
# 如果两种语言都用 72 列，切中文后整框会横向拉长一倍（实测 600px → 1201px），
# 看起来像"框子被拉变形"。
# 所以按**目标像素宽度**折算列数：两边的框看起来一样宽。
UI_TARGET_PX=576      # 72 列 × 8px
UI_W=72               # 当前语言的界面列数（由 ui_init_layout 计算）
UI_COLS=3             # 当前语言的菜单列数（英文 3 列、中文 2 列）
UI_RULE=""

ui_init_layout() {
    # 注意用 ${VAR:-}：这个函数在文件顶部就被调用，而 AI_BOOT_LANG 在后面才定义，
    # 写成 "$AI_BOOT_LANG" 会在 set -u 下直接 "unbound variable" 让整个脚本起不来。
    if [ "${AI_BOOT_LANG:-en}" = "zh" ]; then
        # 16px/格 → 576/16 = 36 列；取 40 列（640px）稍微宽一点，避免中文行太挤
        UI_W=38
        UI_COLS=2
    else
        UI_W=72
        UI_COLS=3
    fi
    UI_RULE="$(printf '%*s' "$UI_W" '' | tr ' ' '-')"
}
_UI_PROBE="中文字"
if [ "${#_UI_PROBE}" -eq 3 ]; then
    UI_MULTIBYTE=1
else
    UI_MULTIBYTE=0
fi
ui_init_layout

# 按**显示列**截断，末尾用 ~ 表示被截断。用于长路径这类必然超宽的内容。
ui_cut() {
    local s="$1" max="$2" out="" ch w=0 cw i
    for ((i = 0; i < ${#s}; i++)); do
        ch="${s:i:1}"
        # ASCII 可打印是 0x20-0x7E。这里不用 case：
        #   * case 的模式里不能带空格，[ -~] 写不进去；
        #   * 写成 [!-~] 会变成"不是 - 和 ~"，ASCII 字母被当成 2 列；
        #   * [![:print:]] 在 UTF-8 locale 下把汉字也算作 printable，同样错。
        # 参数展开里可以带空格，所以直接用替换判断（与 disp_width 同一套判据）。
        if [ -n "$ch" ] && [ "$ch" = "${ch//[ -~]/}" ]; then
            cw=2
        else
            cw=1
        fi
        # 省略号本身也要占 1 列，所以这里跟 max-1 比，否则截断后会超宽 1 列
        if [ $((w + cw)) -gt $((max - 1)) ]; then
            printf '%s~' "$out"
            return 0
        fi
        out="$out$ch"
        w=$((w + cw))
    done
    printf '%s' "$out"
}

ui_rule()  { printf '+%s+\n' "$UI_RULE"; }
ui_blank() { printf '| %*s |\n' "$UI_W" ''; }

ui_line() {
    # 注意：下面这些赋值必须分开写。写成
    #     local s="$1" chars=${#s} t="${s//[ -~]/}"
    # 是不行的 —— bash 先把所有词展开完再赋值，${#s} 拿到的是外层旧的 s。
    local s="$1"
    local chars wide t n
    # 值里混进 TAB/CR/LF（手工编辑过的配置很常见）会让这一行的列宽算错，
    # 统一换成空格。
    s="${s//$'\t'/ }"
    s="${s//$'\r'/ }"
    s="${s//$'\n'/ }"
    chars=${#s}
    wide=0
    if [ "$UI_MULTIBYTE" = "1" ]; then
        t="${s//[ -~]/}"
        wide=${#t}
    fi
    # 超宽内容（长挂载点路径等）必须截断，否则折行会把 ASCII 边框冲散
    if [ $((chars + wide)) -gt "$UI_W" ]; then
        s="$(ui_cut "$s" "$UI_W")"
        chars=${#s}
        wide=0
        if [ "$UI_MULTIBYTE" = "1" ]; then
            t="${s//[ -~]/}"
            wide=${#t}
        fi
    fi
    n=$((UI_W - chars - wide))
    [ "$n" -lt 0 ] && n=0
    printf '| %s%*s |\n' "$s" "$n" ''
}

# 一个字符串占多少**显示列**：ASCII 1 列，非 ASCII 2 列。
# 中英混排的表格要靠它对齐，否则中文串用 %-18s 补出来会歪。
disp_width() {
    local s="$1" chars wide t
    chars=${#s}
    wide=0
    if [ "$UI_MULTIBYTE" = "1" ]; then
        t="${s//[ -~]/}"
        wide=${#t}
    fi
    printf '%s' "$((chars + wide))"
}

# 把 $1 左对齐补到 $2 个显示列
ui_pad() {
    # 宽度计算内联，不再套一层 $(disp_width)：菜单每帧要调十几次，
    # 每次多一个子 shell，在慢机器上会明显拖慢重绘。
    local s="$1" want="$2" chars wide probe w pad
    chars=${#s}
    wide=0
    if [ "$UI_MULTIBYTE" = "1" ]; then
        probe="${s//[ -~]/}"
        wide=${#probe}
    fi
    w=$((chars + wide))
    pad=$((want - w))
    [ "$pad" -lt 0 ] && pad=0
    printf '%s%*s' "$s" "$pad" ''
}

ui_title() { ui_rule; ui_line "$1"; ui_rule; }
ui_foot()  { ui_rule; }

# 每个子界面底部都显示同一句提示，ESC 的行为才是可预期的。
# 文案走 t()，切到中文时这句也跟着变（4.1 里 t() 原本是死代码，
# 定义了却没人调用，等于语言开关只翻了主菜单标题）。
ui_nav() {
    local extra="${1:-}"
    ui_rule
    if [ -n "$extra" ]; then
        ui_line "$extra"
    fi
    ui_line "$(t nav_back)"
    ui_rule
}

# ============================================================
# 三、日志
# ============================================================
LOG_FILE=""

log() {
    local msg="$1"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    case "${CFG[log_level]:-info}" in
        debug) echo "[$ts] $msg" ;;
        *)     : ;;
    esac
    if [ -n "${LOG_FILE:-}" ] && [ "${CFG[log_save_usb]:-1}" = "1" ]; then
        echo "[$ts] $msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

die() {
    echo "FATAL: $1" >&2
    log "FATAL: $1"
    exit 1
}

gen_random_password() {
    local len="${1:-16}"
    tr -dc '0-9' < /dev/urandom 2>/dev/null | head -c "$len"
}

# ============================================================
# 四、配置文件
# ============================================================
# 顺序即文件的书写顺序。每个键都必须真的有人用，否则就该删掉。
CFG_KEYS="auto_config auto_save lang \
wifi_auto_connect wifi_ssid wifi_password \
wired_dhcp static_ip static_mask static_gateway static_dns \
hotspot_enabled hotspot_ssid hotspot_password \
phone_hotspot_ssid phone_hotspot_password \
ai_user ai_done_file ai_estop_file ssh_port ssh_allow_root \
log_level log_save_usb"

declare -A CFG_DEFAULT=(
    [auto_config]=1
    [auto_save]=1
    [lang]=en
    [wifi_auto_connect]=1
    [wifi_ssid]=""
    [wifi_password]=""
    [wired_dhcp]=1
    [static_ip]=""
    [static_mask]=""
    [static_gateway]=""
    [static_dns]=""
    [hotspot_enabled]=1
    [hotspot_ssid]=""
    [hotspot_password]=""
    # 手机热点 = 去连别人的热点（全自动模式用；留空则跳过）
    # 本机热点 = 这台电脑自己开热点（hotspot_* 那几个键）
    [phone_hotspot_ssid]=""
    [phone_hotspot_password]=""
    [ai_user]=ai
    # 两个标记语义完全不同，5.0 拆开：
    #   ai_done_file  = AI 自己说"我干完了"（AI touch 它）
    #   ai_estop_file = 操作者按了急停（只有人能写、只有人能清）
    # 4.x 只有一个 ai_stop_file，被"AI 完工"和"人工急停"两种相反含义共用。
    [ai_done_file]=/root/.ai-done
    [ai_estop_file]=/root/.ai-estop
    [ssh_port]=22
    [ssh_allow_root]=0
    [log_level]=info
    [log_save_usb]=1
)
declare -A CFG=()

USB_ROOT=""
AI_BOOT_DIR=""
CONFIG_FILE=""
PASS_FILE=""
GUIDE_FILE=""
CFG_WRITABLE=0
CFG_VOLATILE=0
LANG_FILE=""

# 找 U 盘：认 AI-Boot 目录，也认直接放在分区根上的 ai-boot.conf
find_usb_root() {
    local base d
    for base in /run/media /media /mnt \
                /run/live/medium /lib/live/mount/medium \
                /run/media/*/* ; do
        [ -d "$base" ] || continue
        if [ -d "$base/AI-Boot" ] || [ -f "$base/ai-boot.conf" ]; then
            printf '%s\n' "$base"; return 0
        fi
        while IFS= read -r d; do
            if [ -d "$d/AI-Boot" ] || [ -f "$d/ai-boot.conf" ]; then
                printf '%s\n' "$d"; return 0
            fi
        done < <(find "$base" -mindepth 1 -maxdepth 4 -type d 2>/dev/null)
    done
    return 1
}

init_paths() {
    local cand=""
    USB_ROOT="$(find_usb_root || true)"
    CFG_WRITABLE=0
    CFG_VOLATILE=1

    if [ -n "$USB_ROOT" ]; then
        cand="$USB_ROOT/AI-Boot"
    fi

    # 优先 U 盘：能写就用它，不能写就只读它（并让上层给出警告）
    if [ -n "$cand" ]; then
        mkdir -p "$cand/logs" 2>/dev/null || true
        if touch "$cand/.wtest" 2>/dev/null; then
            rm -f "$cand/.wtest" 2>/dev/null || true
            AI_BOOT_DIR="$cand"
            CFG_WRITABLE=1
            CFG_VOLATILE=0
        elif [ -f "$cand/ai-boot.conf" ]; then
            AI_BOOT_DIR="$cand"
            CFG_WRITABLE=0
            CFG_VOLATILE=0
        fi
    fi

    # 兜底：内存里（重启即失，上层必须提示用户）
    if [ -z "$AI_BOOT_DIR" ]; then
        AI_BOOT_DIR="/run/ai-boot"
        CFG_WRITABLE=1
        CFG_VOLATILE=1
    fi

    CONFIG_FILE="$AI_BOOT_DIR/ai-boot.conf"
    PASS_FILE="$AI_BOOT_DIR/pass.txt"
    GUIDE_FILE="$AI_BOOT_DIR/guide.txt"
    LOG_FILE="$AI_BOOT_DIR/logs/ai-boot.log"
    mkdir -p "$AI_BOOT_DIR/logs" 2>/dev/null || true

    LANG_FILE="$AI_BOOT_DIR/lang"
    export AI_BOOT_DIR CONFIG_FILE PASS_FILE GUIDE_FILE LOG_FILE LANG_FILE
}

# ── 5.0：配置文件位置可切换（选盘后用）+ 候选盘列举 ──────────────────
# 把"AI-Boot 工作目录"整体换到指定路径：配置、密码、引导文件、日志、语言文件
# 都跟着走，避免只改 CONFIG_FILE 导致几处位置互相矛盾。
ai_boot_set_dir() {
    AI_BOOT_DIR="$1"
    CONFIG_FILE="$AI_BOOT_DIR/ai-boot.conf"
    PASS_FILE="$AI_BOOT_DIR/pass.txt"
    GUIDE_FILE="$AI_BOOT_DIR/guide.txt"
    LOG_FILE="$AI_BOOT_DIR/logs/ai-boot.log"
    LANG_FILE="$AI_BOOT_DIR/lang"
    export AI_BOOT_DIR CONFIG_FILE PASS_FILE GUIDE_FILE LOG_FILE LANG_FILE
    mkdir -p "$AI_BOOT_DIR/logs" 2>/dev/null || true
}

# 可以写配置的候选位置。每行：设备|挂载点|卷标|剩余|是否U盘
# 只用 /proc/mounts + 可选的 blkid/df：不依赖 lsblk，缺工具也能工作（兼容性优先）。
# 5.1 起**排除 Live 系统自己的根目录**：那是内存 overlay，把配置写进去重启就没了，
# 而用户会以为已经存到 U 盘上 —— 这正是"配置老是丢"的一个隐蔽原因。
cfg_targets() {
    local dev mp fstype rest label free rm base devname
    local usb="" other=""
    while read -r dev mp fstype rest; do
        case "$dev" in /dev/*) ;; *) continue ;; esac
        case "$fstype" in
            squashfs|iso9660|tmpfs|devtmpfs|proc|sysfs|overlay|autofs|ramfs|nsfs|efivarfs) continue ;;
        esac
        case "$rest" in ro,*|*,ro,*|*,ro) continue ;; esac
        case "$mp" in
            /|/run/live*|/lib/live*|/run/initramfs*|/run/ai-boot*) continue ;;
        esac
        label=""
        command -v blkid >/dev/null 2>&1 && label="$(blkid -s LABEL -o value "$dev" 2>/dev/null | head -n1)"
        free="$(df -h "$mp" 2>/dev/null | awk 'NR==2{print $4}')"
        rm=""
        devname="$(basename "$dev")"
        base="${devname%%[0-9]*}"
        if [ -r "/sys/block/$base/removable" ] && [ "$(cat "/sys/block/$base/removable" 2>/dev/null)" = "1" ]; then
            rm="USB"
        fi
        if [ -n "$rm" ]; then
            usb="$usb$(printf '%s|%s|%s|%s|%s\n' "$dev" "$mp" "$label" "$free" "$rm")"$'\n'
        else
            other="$other$(printf '%s|%s|%s|%s|%s\n' "$dev" "$mp" "$label" "$free" "$rm")"$'\n'
        fi
    done < /proc/mounts
    # U 盘优先（用户最可能想写到 U 盘）
    printf '%s%s' "$usb" "$other"
}

# 布尔键的显示：0/1 对普通人是天书，统一显示成 开(1)/关(0)
cfg_bool_text() {
    case "$1" in
        1|on|yes|true|开) printf '%s' "$(t cfg_on)" ;;
        0|off|no|false|关) printf '%s' "$(t cfg_off)" ;;
        '') printf '%s' "$(t cfg_empty)" ;;
        *)  printf '%s' "$1" ;;
    esac
}

cfg_is_bool_key() {
    case "$1" in
        auto_config|auto_save|wifi_auto_connect|wired_dhcp|hotspot_enabled|ssh_allow_root|log_save_usb) return 0 ;;
        *) return 1 ;;
    esac
}

# 校验并规范化一个新值。成功则把结果写进 CFG_NEWVAL 并返回 0。
cfg_validate() {
    local key="$1" val="$2" p
    case "$key" in
        auto_config|auto_save|wifi_auto_connect|wired_dhcp|hotspot_enabled|ssh_allow_root|log_save_usb)
            case "$val" in
                1|on|ON|yes|YES|true|开)  CFG_NEWVAL=1; return 0 ;;
                0|off|OFF|no|NO|false|关) CFG_NEWVAL=0; return 0 ;;
                *) return 1 ;;
            esac ;;
        ssh_port)
            case "$val" in ''|*[!0-9]*) return 1 ;; esac
            [ "$val" -ge 1 ] && [ "$val" -le 65535 ] && { CFG_NEWVAL="$val"; return 0; }
            return 1 ;;
        log_level)
            case "$val" in
                info|debug|warn|error) CFG_NEWVAL="$val"; return 0 ;;
                *) return 1 ;;
            esac ;;
        lang)
            case "$val" in
                en|zh) CFG_NEWVAL="$val"; return 0 ;;
                *) return 1 ;;
            esac ;;
        *)
            CFG_NEWVAL="$val"; return 0 ;;
    esac
}

# ── 5.1：AI 登录前必须成立的两件事 ──────────────────────────────
# 都是"只有真的用 SSH 登录进去才会暴露"的问题（靠看界面永远发现不了）：
#   1) /home/ai 的属主：构建时 tar --owner=0 把家目录也变成了 root:root 0700，
#      AI 一登录就报 "Could not chdir to home directory /home/ai: Permission denied"
#   2) /etc/hosts 空：sudo 每次都报 "unable to resolve host (none)"
ensure_system_ready() {
    if [ -d /home/ai ]; then
        local owner
        owner="$(stat -c '%u:%g' /home/ai 2>/dev/null || echo '')"
        if [ "$owner" != "1000:1000" ]; then
            # 递归：家目录里的 .bashrc/.profile 等也必须是 ai 的，
            # 否则登录后仍报 "bash: /home/ai/.bashrc: Permission denied"
            chown -R 1000:1000 /home/ai 2>/dev/null || true
        fi
        chmod 0700 /home/ai 2>/dev/null || true
    fi
    if [ ! -s /etc/hosts ]; then
        {
            echo '127.0.0.1 localhost'
            printf '127.0.1.1 %s\n' "$(cat /etc/hostname 2>/dev/null || echo debian)"
        } >> /etc/hosts 2>/dev/null || true
    fi
    return 0
}

# ── 5.1 关键修复：sshd 的权限分离用户 ────────────────────────────────
# sshd 需要一个叫 sshd 的系统用户做权限分离；镜像里**没有**这个用户时，
# sshd 会直接拒绝启动并报：
#     Privilege separation user sshd does not exist
# 表现就是"AI 永远连不上"，而界面上只看到端口没监听 —— 极难排查。
# 这里在启动 sshd 之前自愈一次：缺了就补上（同时补 group 和 /run/sshd）。
ensure_privsep_user() {
    [ -f /etc/passwd ] || return 0
    if ! grep -q '^sshd:' /etc/passwd 2>/dev/null; then
        # uid/gid 取 106（镜像里 105 被 colord 占用，见 /etc/passwd）
        printf 'sshd:x:106:65534::/run/sshd:/usr/sbin/nologin\n' >> /etc/passwd 2>/dev/null || true
        log "created missing sshd privilege-separation user"
    fi
    if [ -f /etc/group ] && ! grep -q '^sshd:' /etc/group 2>/dev/null; then
        printf 'sshd:x:106:\n' >> /etc/group 2>/dev/null || true
    fi
    mkdir -p /run/sshd 2>/dev/null || true
    chmod 0755 /run/sshd 2>/dev/null || true
    return 0
}

# sshd 起不来的原因很多，但最常见的两个各有明确特征，这里给出**人话结论**
sshd_diagnose() {
    if ! grep -q '^sshd:' /etc/passwd 2>/dev/null; then
        printf '%s' "$(t ssh_diag_privsep)"
        return 0
    fi
    if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
        printf '%s' "$(t ssh_diag_hostkey)"
        return 0
    fi
    printf '%s' "$(t ssh_diag_unknown)"
    return 0
}

# 读取配置：先把默认值铺满，再用文件里的键覆盖
#
# CFG_FROM_FILE 记录“这个键是配置文件里真写了的”。
# 必须有这个区分，否则 cfg_get 永远返回默认值，
# 任何“没写就用别处的值”的判断都会失效 —— lang 就是这么坏的：
# 初始化时写的是 `if [ -n "$(cfg_get lang)" ]`，而默认值就是 en，
# 条件恒真，后面“读上次选择的语言文件”那一档永远走不到（已实测）。
declare -A CFG_FROM_FILE=()
cfg_load() {
    local k line key val
    CFG=()
    CFG_FROM_FILE=()
    for k in "${!CFG_DEFAULT[@]}"; do
        CFG[$k]="${CFG_DEFAULT[$k]}"
    done
    [ -f "$CONFIG_FILE" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        case "$line" in
            *=*) : ;;
            *)   continue ;;
        esac
        key="${line%%=*}"
        key="${key#$'\xEF\xBB\xBF'}"
        val="${line#*=}"
        key="$(printf '%s' "$key" | tr -d ' \t\r')"
        val="$(printf '%s' "$val" | tr -d '\r')"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        if [ -n "$key" ]; then
            CFG[$key]="$val"
            CFG_FROM_FILE[$key]=1
        fi
    done < "$CONFIG_FILE"

    # 兼容 4.x 的 U 盘配置：那时只有一个 ai_stop_file，被"AI 完工"与"人工急停"
    # 两种相反含义共用。老配置按"AI 完工标记"解释（AI 自己 touch 的那个），
    # 并且不再把它写回文件（避免两套键长期共存让人更糊涂）。
    if [ -n "${CFG_FROM_FILE[ai_stop_file]:-}" ]; then
        [ -n "${CFG[ai_stop_file]}" ] && CFG[ai_done_file]="${CFG[ai_stop_file]}"
        CFG_FROM_FILE[ai_done_file]=1
        unset 'CFG[ai_stop_file]' 'CFG_FROM_FILE[ai_stop_file]'
    fi
    return 0
}

# 把内存里的配置写回文件（按 CFG_KEYS 的顺序，未知键保留在末尾）
cfg_write() {
    if [ "$CFG_WRITABLE" != "1" ]; then
        echo "$(t cfg_write_readonly)$CONFIG_FILE"
        return 1
    fi
    local tmp="$CONFIG_FILE.tmp.$$" k
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
    {
        printf '# AI-Boot %s 配置文件\n' "$AI_BOOT_VERSION"
        printf '# 格式：键=值，每行一个，# 开头是注释。\n'
        printf '# 每个键的实际作用见 /usr/local/share/ai-boot/ai-boot.conf.README\n'
        printf '#\n'
        for k in $CFG_KEYS; do
            printf '%s=%s\n' "$k" "${CFG[$k]:-}"
        done
        while IFS= read -r k; do
            [ -n "$k" ] || continue
            case " $CFG_KEYS " in
                *" $k "*) continue ;;
            esac
            printf '%s=%s\n' "$k" "${CFG[$k]:-}"
        done < <(printf '%s\n' "${!CFG[@]}" | sort)
    } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    mv "$tmp" "$CONFIG_FILE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    # 写回之后这些键就“在文件里存在”了，语言等判断要据此变化
    for k in "${!CFG[@]}"; do
        CFG_FROM_FILE[$k]=1
    done
    return 0
}

cfg_get() {
    local key="$1"
    printf '%s\n' "${CFG[$key]:-}"
}

# 设置一个键。auto_save=0 时只改内存不落盘。
cfg_set() {
    local key="$1" val="$2"
    CFG[$key]="$val"
    # 改 auto_save 本身必须强制落盘：否则"把自动保存关掉"这个动作自己不会被保存，
    # 下次进来又变回 1 —— 用户会以为开关坏了（审计已证实）。
    if [ "$key" = "auto_save" ] || [ "$(cfg_get auto_save)" = "1" ]; then
        cfg_write || return 1
    fi
    return 0
}

cfg_is_on() {
    [ "$(cfg_get "$1")" = "1" ]
}

# ============================================================
# 五、公共小工具
# ============================================================
# ---- 按键回退缓冲 ----
# read_key 为了认出方向键（ESC [ A），读到 ESC 之后必须再探一个字节。
# 如果那个字节不是 '[' 或 'O'，就说明用户是按了「ESC 然后马上又按了别的键」。
# 字节已经被 read 吃掉，tty 上没法塞回去，所以在这里落到文件里，
# 让下一次 read_key 先取它。
#
# 没有这个缓冲的后果（已实测）：喂 `ESC ESC` 给 WiFi 页，第一下 ESC 会把
# 第二下也吃掉，用户看到的是「按一下没返回，得再按一下」—— 正是用户报的现象。
#
# 为什么用文件而不是 shell 变量：read_key 是 `x="$(read_key)"` 这种用法，
# 跑在子 shell 里，赋值传不回父进程；只有文件能跨子 shell 生效。
KEY_PB_FILE=""
KEY_PB_BYTE=""
key_pb_init() {
    local cand
    # 顺序有讲究：先用本届会话自己的目录（U 盘上的 AI-Boot 目录，
    # 或者内存兜底的 /run/ai-boot），再用 /tmp，最后用 TMPDIR ——
    # 有些环境（包括本机这种被改造过的 Termux）/tmp 是只读的。
    for cand in "$AI_BOOT_DIR/.keypush" /tmp/ai-boot.keypush "${TMPDIR:-/tmp}/ai-boot.keypush"; do
        case "$cand" in
            */.keypush|*/ai-boot.keypush) : ;;
            *) continue ;;
        esac
        if ( : > "$cand" ) 2>/dev/null; then
            KEY_PB_FILE="$cand"
            : > "$KEY_PB_FILE" 2>/dev/null || true
            return 0
        fi
    done
    KEY_PB_FILE=""      # 都写不了就退化成原来的“丢掉那个字节”
    return 1
}
key_pb_put() {
    [ -n "$KEY_PB_FILE" ] || return 0
    printf '%s' "$1" > "$KEY_PB_FILE" 2>/dev/null || true
}
key_pb_get() {
    [ -n "$KEY_PB_FILE" ] || return 1
    [ -s "$KEY_PB_FILE" ] || return 1
    KEY_PB_BYTE=""
    IFS= read -r -s -n 1 KEY_PB_BYTE < "$KEY_PB_FILE" 2>/dev/null || return 1
    : > "$KEY_PB_FILE" 2>/dev/null || true
    return 0
}

# 这几个原先是每个模块各抄一份，抄出来的副本已经不一致了：
# ai_user_name 在 ai-monitor.sh 和 ai-password.sh 里各有一份，
# LOCK_FILE 在 ai-ssh.sh 和 ai-rescue.sh 里各有一份。
# 缺一个键的默认值就会让两处行为不同，所以统一放这里。
ai_user_name() {
    local u
    u="$(cfg_get ai_user)"
    [ -n "$u" ] || u="ai"
    printf '%s\n' "$u"
}

# 存在这个文件就等于“禁止远程访问”
LOCK_FILE="$AI_BOOT_DIR/ai-boot.lock"

# 把掩码换成前缀长度。接受两种写法：
#   "255.255.255.0" -> 24      "24" -> 24      空 -> 24
# 放在公共库里是因为 ai-network.sh 和 ai-config.sh 都要用它做校验，
# 而 ai-config.sh 并不 source ai-network.sh。4.0 里这个键整个是死的。
netmask_to_prefix() {
    local mask="$1" part n=0
    case "$mask" in
        '')   echo 24; return 0 ;;
        *.*)  : ;;                       # 点分掩码，往下走
        *)    echo "$mask"; return 0 ;;  # 已经是前缀长度
    esac
    local IFS=.
    for part in $mask; do
        case "$part" in
            255) n=$((n + 8)) ;; 254) n=$((n + 7)) ;;
            252) n=$((n + 6)) ;; 248) n=$((n + 5)) ;;
            240) n=$((n + 4)) ;; 224) n=$((n + 3)) ;;
            192) n=$((n + 2)) ;; 128) n=$((n + 1)) ;;
            *)   : ;;
        esac
    done
    echo "$n"
}

# ============================================================
# 六、语言
# ============================================================
# 只用它翻主界面和公共提示；子界面仍是英文（AI-README 明确要求英文日志）。
# 不假装“已完整中文”，见发布说明。
AI_BOOT_LANG="en"

# ------------------------------------------------------------
# 中英文案表。要求（《规划与要求》第 7、20 条）：
#   默认英文，按 L 切换中文；中文要覆盖所有界面；翻不出来就回落英文。
# 实现方式：同一个 key 在中英两个 case 里各写一份；中文缺这个 key 时
# 会落到英文那份，英文也没有才原样打印 key —— 永远不会因为翻译缺失
# 而显示成方块或空白。
# ------------------------------------------------------------
t() {
    local key="$1"
    if [ "$AI_BOOT_LANG" != "zh" ]; then
        case "$key" in
            nav_back)        echo "ESC = back one level      X = same as ESC" ;;
            nav_hint)        echo "ESC/X = back      digits = select      ENTER = redraw" ;;
            menu_countdown)  echo "AUTO RESCUE IN" ;;
            menu_anykey)     echo "press any key to cancel" ;;
            menu_overall)    echo "-- OVERALL CONFIG --" ;;
            menu_individual) echo "-- INDIVIDUAL CONFIG --" ;;
            menu_settings)   echo "-- SETTINGS --" ;;
            menu_system)               echo "-- SYSTEM (careful) --" ;;
            menu_a)          echo "A. Rescue mode" ;;
            menu_b)          echo "B. Guided configuration" ;;
            menu_c)          echo "C. Auto config" ;;
            menu_d)          echo "D. Auto save" ;;
            menu_e)          echo "E. Edit config file" ;;
            menu_f)          echo "F. Default config" ;;
            menu_g)          echo "G. USB config file" ;;
            menu_h)          echo "H. Help" ;;
            menu_l)          echo "L. Language" ;;
            menu_r)          echo "R. Reboot" ;;
            menu_s)          echo "S. Shutdown" ;;
            menu_1)          echo "1. SSH" ;;
            menu_2)          echo "2. WiFi / Refresh" ;;
            menu_3)          echo "3. Password file" ;;
            menu_4)          echo "4. Command line" ;;
            menu_5)          echo "5. Windows tools" ;;
            menu_6)          echo "6. File browser" ;;
            menu_7)          echo "7. Backup to shared" ;;
            menu_8)          echo "8. Self-check" ;;
            menu_9)          echo "" ;;
            menu_nav1)       echo "ESC / X : exit to command line      L : language" ;;
            menu_nav2)       echo "digits  : select      ENTER : redraw" ;;
            menu_readonly)   echo "!! config is READ-ONLY:" ;;
            menu_volatile)   echo "!! no USB AI-Boot dir: config is in RAM" ;;
            exit_title)      echo "Exit AI-Boot main menu" ;;
            exit_line1)      echo "You will get a local root shell." ;;
            exit_line2)      echo "Type exit in the shell to come back to this menu." ;;
            exit_confirm)    echo "Exit to command line?" ;;
            ssh_title)       echo "SSH connection card" ;;
            ssh_ip)          echo "IP" ;;
            ssh_port)        echo "port" ;;
            ssh_user)        echo "user" ;;
            ssh_cmd)         echo "command" ;;
            ssh_pw)          echo "password" ;;
            ssh_root_same)   echo "root password is the same" ;;
            ssh_readme)      echo "after login read" ;;
            ssh_not_listening) echo "WARNING: nothing is listening on the SSH port." ;;
            # shared
            press_any) echo "Press any key to continue (ESC = back one level)..." ;;
            common_esc_abort)          echo " (ESC to abort)" ;;
            common_cancelled)          echo "-- cancelled" ;;
            common_timeout_cancel)     echo "-- timed out, treating as cancel" ;;
            common_yn_hint)            echo "(please type Y or N)" ;;
            common_confirm_default)    echo "Are you sure?" ;;
            cfg_write_readonly)        echo "Config location is read-only, not written back: " ;;
            warn_readonly)             echo "WARNING: the config location is read-only; changes will NOT be saved." ;;
            warn_volatile)             echo "WARNING: no AI-Boot dir on the USB stick; config lives in RAM and is lost on reboot." ;;
            warn_where)                echo "      location: " ;;
            # config page (ai-config.sh)
            cfg_where_title)           echo "Config file location" ;;
            cfg_path)                  echo "Path: " ;;
            cfg_ro_title)            echo "This location is READ-ONLY" ;;
            cfg_ro_line)             echo "Changes cannot be saved to: " ;;
            cfg_save_nano)           echo "  Save: Ctrl+O then Enter.   Quit: Ctrl+X." ;;
            cfg_save_vi)             echo "  Save and quit: press Esc, type :wq and Enter.   Quit without saving: Esc then :q!" ;;
            cfg_toggle_same)         echo "Unchanged." ;;
            cfg_unsaved_confirm)     echo "Leave WITHOUT writing the changes?" ;;
            cfg_reload_confirm)      echo "Reload from the file and lose your unsaved changes?" ;;
            cfg_reset_confirm2)      echo "This OVERWRITES the whole file and cannot be undone: " ;;
            cfg_on)                  echo "ON(1)" ;;
            cfg_off)                 echo "OFF(0)" ;;
            cfg_source)              echo "Source: " ;;
            cfg_source_file)         echo "the config file on the disk" ;;
            cfg_source_mem)          echo "in-memory defaults (there is NO config file yet)" ;;
            cfg_howto_t1)            echo "To make it load automatically, put ai-boot.conf on the USB stick:" ;;
            cfg_howto_t2)            echo "  <USB>/AI-Boot/ai-boot.conf   (or right in the USB root)" ;;
            cfg_howto_t3)            echo "Without a file the built-in defaults are used; changes are lost on reboot." ;;
            cfg_howto_keys)          echo "Keys: E edit item by item   G edit the raw file   ESC back" ;;
            cfg_pick_title)          echo "Which disk should the config be written to?" ;;
            cfg_pick_mem)            echo "in memory only (/run/ai-boot, lost on reboot)" ;;
            cfg_pick_hint)           echo "Type the number and press ENTER. ESC cancels." ;;
            cfg_pick_current)        echo "Currently selected: " ;;
            cfg_pick_use_this)       echo "Write to this location?" ;;
            cfg_pick_cancel)         echo "No location chosen." ;;
            cfg_nolabel)             echo "(no label)" ;;
            cfg_free)                echo "free" ;;
            cfg_mount)               echo "mount: " ;;
            cfg_create_title)        echo "There is no config file yet" ;;
            cfg_create_ask)          echo "Do you want to create one now? It will be written to:" ;;
            cfg_create_confirm)      echo "Create the config file now?" ;;
            cfg_create_skip)         echo "Not created - changes stay in memory and are lost on reboot." ;;
            cfg_create_fail)         echo "Could not create the directory (read-only disk?)." ;;
            cfg_unsaved_warn)        echo "You have changes that were NOT written to the file." ;;
            cfg_unsaved_write)       echo "S write them now" ;;
            cfg_unsaved_drop)        echo "ESC/X discard them and leave" ;;
            cfg_invalid_bool)        echo "Please type 1 or 0 (1 = ON, 0 = OFF)." ;;
            cfg_invalid_port)        echo "Please type a port number between 1 and 65535." ;;
            cfg_invalid_level)       echo "Please type one of: info, debug, warn, error." ;;
            cfg_saved_mem)           echo "changed in memory only (auto save is OFF, or no file yet)" ;;
            cfg_toggle_hint)         echo "Press 1 to turn it ON, 0 to turn it OFF, ESC keeps it as it is." ;;
            cfg_guide_help1)         echo "To use this, create a plain text file named guide.txt on the USB stick:" ;;
            cfg_guide_help2)         echo "  <USB>/AI-Boot/guide.txt   - it is only DISPLAYED here, never executed." ;;
            cfg_writable_yes)          echo "Writable: yes" ;;
            cfg_writable_no)           echo "Writable: no (changes will NOT be saved!)" ;;
            cfg_persist_no)            echo "Persistent: no (in memory, lost on reboot)" ;;
            cfg_persist_reason)        echo "Reason: no AI-Boot dir found on the USB stick" ;;
            cfg_persist_yes)           echo "Persistent: yes (on the USB stick)" ;;
            cfg_usb_mount)             echo "USB mount point: " ;;
            cfg_current_list)          echo "Config in effect right now (defaults included):" ;;
            cfg_default_title)         echo "Default config" ;;
            cfg_default_note)          echo "Applies when there is no config file, or after a reset with D:" ;;
            cfg_guide_title)           echo "Guide config (rescue order)" ;;
            cfg_guide_s1)              echo "Step 1: read this config to get online (needs auto_config=1)" ;;
            cfg_guide_s2)              echo "Step 2: wired DHCP" ;;
            cfg_guide_s3)              echo "Step 3: phone hotspot" ;;
            cfg_guide_s4)              echo "Step 4: local hotspot" ;;
            cfg_guide_s5)              echo "Step 5: fall back to the local command line" ;;
            cfg_guide_note)            echo "Every failing step rolls over to the next one; nothing gets stuck." ;;
            cfg_guidefile_title)       echo "Guide file" ;;
            cfg_file_missing)          echo "File does not exist: " ;;
            cfg_file_label)            echo "File: " ;;
            cfg_guide_read_confirm)    echo "Read this guide file?" ;;
            cfg_read_fail)             echo "Read failed" ;;
            cfg_edit_title)            echo "Edit" ;;
            cfg_desc)                  echo "Desc: " ;;
            cfg_cur)                   echo "Current: " ;;
            cfg_secret_cur_pre)        echo "Current: ******** (" ;;
            cfg_secret_cur_suf)        echo " chars)" ;;
            cfg_empty)                 echo "(empty)" ;;
            cfg_edit_hint)             echo "ENTER=keep    - =clear    ESC=cancel" ;;
            cfg_newval)                echo "New value: " ;;
            cfg_saved)                 echo "Saved: " ;;
            cfg_save_fail)             echo "Write failed (location read-only?): " ;;
            cfg_edit_list_title)       echo "Edit item by item (type the number, then press ENTER)" ;;
            cfg_edit_keys)             echo "S write now   R reload   D defaults   W how to use this file" ;;
            cfg_no_item_a)             echo "No item " ;;
            cfg_no_item_b)             echo "." ;;
            cfg_written)               echo "Written back to: " ;;
            cfg_write_fail)            echo "Write-back failed." ;;
            cfg_reloaded)              echo "Reloaded." ;;
            cfg_reset_confirm)         echo "Reset every key to its default?" ;;
            cfg_reset_done)            echo "Defaults restored." ;;
            cfg_no_editor_title)       echo "No editor available" ;;
            cfg_no_editor_l1)          echo "This system has no nano / vim / vi." ;;
            cfg_no_editor_l2)          echo "Falling back to item editing: same function, cannot corrupt the file." ;;
            cfg_open_a)                echo "Opening with " ;;
            cfg_open_b)                echo ": " ;;
            cfg_editor_hint)           echo "(after saving and quitting, press any key to return to the menu)" ;;
            cfg_editor_fail)           echo "failed to start; switching to item-by-item editing." ;;
            cfg_old)                   echo "Old: " ;;
            cfg_new)                   echo "   New: " ;;
            cfg_toggle_saved)          echo "saved" ;;
            cfg_toggle_mem)            echo "in memory only (location read-only)" ;;
            cfg_lang_title)            echo "Language" ;;
            cfg_lang_zh)               echo "2. Chinese (main menu and shared prompts)" ;;
            cfg_switched_en)           echo "Switched to English." ;;
            cfg_switched_zh)           echo "Switched to Chinese (some screens are still English; see release notes)." ;;
            cfg_name_autocfg)          echo "Auto config switch" ;;
            cfg_name_autosave)         echo "Auto save switch" ;;
            cfg_lbl_auto_config)       echo "master switch: rescue mode reads this config 0/1" ;;
            cfg_lbl_auto_save)         echo "write changes back to this file automatically 0/1" ;;
            cfg_lbl_lang)              echo "UI language en/zh" ;;
            cfg_lbl_wifi_auto_connect) echo "rescue stage: auto connect with the SSID below 0/1" ;;
            cfg_lbl_wifi_ssid)         echo "WiFi name used for the auto connect" ;;
            cfg_lbl_wifi_password)     echo "WiFi password used for the auto connect" ;;
            cfg_lbl_wired_dhcp)        echo "try wired DHCP 0/1" ;;
            cfg_lbl_static_ip)         echo "static IP (empty = use DHCP)" ;;
            cfg_lbl_static_mask)       echo "static netmask, 24 or 255.255.255.0" ;;
            cfg_lbl_static_gateway)    echo "static gateway" ;;
            cfg_lbl_static_dns)        echo "static DNS" ;;
            cfg_lbl_hotspot_enabled)   echo "rescue stage: enable the phone hotspot step 0/1" ;;
            cfg_lbl_hotspot_ssid)      echo "local hotspot name (empty = random)" ;;
            cfg_lbl_hotspot_password)  echo "local hotspot password (empty = random)" ;;
            cfg_lbl_phone_hotspot_ssid)     echo "phone hotspot name (for fully automatic rescue; empty = skip)" ;;
            cfg_lbl_phone_hotspot_password) echo "phone hotspot password (for fully automatic rescue)" ;;
            cfg_lbl_ai_user)           echo "user allowed to log in over SSH" ;;
            cfg_lbl_ai_done_file)      echo "AI finished marker (the AI touches it when done)" ;;
            cfg_lbl_ai_estop_file)     echo "emergency-stop marker (only the operator sets it)" ;;
            cfg_lbl_ssh_port)          echo "SSH port" ;;
            cfg_lbl_ssh_allow_root)    echo "allow root to log in over SSH directly 0/1" ;;
            cfg_lbl_log_level)         echo "log level info/debug" ;;
            cfg_lbl_log_save_usb)      echo "write logs to the USB stick 0/1" ;;
            # help page (ai-help.sh)
            help_title)      echo "Help  AI-Boot" ;;
            help_keys_title) echo "Key conventions (the same everywhere):" ;;
            help_k1)         echo "  ESC  go back one level (one press, on every screen)" ;;
            help_k2)         echo "  X    same as ESC, kept from 4.0" ;;
            help_k3)         echo "  digit  pick that entry, then press ENTER" ;;
            help_k4)         echo "  ENTER  confirm / redraw this screen" ;;
            help_k5)        echo "  L    switch language (English / Chinese)" ;;
            help_menu_title) echo "Main menu entries:" ;;
            help_m1)         echo "  A guides   B guide file   C auto config   D auto save" ;;
            help_m2)         echo "  E edit config   F default config   G raw config file" ;;
            help_m3)         echo "  1 SSH   2 WiFi   3 rescue   4 password   5 shell" ;;
            help_m4)         echo "  6 Windows tools   7 file browser   8 backup   9 self-check" ;;
            help_m5)         echo "  L language   R reboot   S shutdown" ;;
            help_cfg)        echo "Config file: " ;;
            help_note1)      echo "SSH user: from ai_user (default ai); password: random on every boot." ;;
            help_note2)      echo "After logging in, read /usr/local/share/ai-boot/AI-README.txt first." ;;
            # tools page (ai-tools.sh)
            tools_win_title)    echo "Windows tools" ;;
            tools_w1)           echo "1. List disks / partitions" ;;
            tools_w2)           echo "2. Mount a Windows partition" ;;
            tools_w3)           echo "3. Repair Windows boot        (hint only)" ;;
            tools_w4)           echo "4. Back up Windows files        (hint only)" ;;
            tools_w5)           echo "5. Write a Windows ISO to USB   (hint only)" ;;
            tools_disk_title)   echo "Disks / partitions" ;;
            tools_nolsblk)      echo "lsblk unavailable" ;;
            tools_mnt_title)    echo "Mount a Windows partition" ;;
            tools_mnt_ex)       echo "for example: /dev/sda2" ;;
            tools_mnt_prompt)   echo "Partition (ESC to cancel): " ;;
            tools_mnt_ok)       echo "Mounted at /mnt/win" ;;
            tools_mnt_fail)     echo "Mount failed. Possible reasons:" ;;
            tools_mnt_r1)       echo "  - wrong partition name (press 1 to look first)" ;;
            tools_mnt_r2)       echo "  - NTFS is dirty/hibernated (shut Windows down completely first)" ;;
            tools_mnt_r3)       echo "  - ntfs-3g needed: " ;;
            tools_fix_title)    echo "Repair Windows boot (hint only)" ;;
            tools_fix_line)     echo "This version does not repair automatically; do it by hand:" ;;
            tools_fix_s1)       echo "1) In Windows: " ;;
            tools_fix_s2)       echo "   (S: is the EFI partition drive letter)" ;;
            tools_fix_s3)       echo "2) Or in Linux: " ;;
            tools_fix_s5)       echo "   sudo fdisk -l   # find the EFI partition" ;;
            tools_fix_s7a)      echo "   check that " ;;
            tools_fix_s7b)      echo " exists" ;;
            tools_bak_title)    echo "Back up Windows files (hint only)" ;;
            tools_bak_line)     echo "Mount with 2 first, then do it by hand:" ;;
            tools_iso_title)    echo "Write a Windows ISO (hint only)" ;;
            tools_iso_line)     echo "This wipes the target disk, so this version will not do it. Template:" ;;
            tools_iso_s1)       echo "lsblk                                  # confirm the device name first" ;;
            tools_iso_warn)     echo "of= must be the device, not a partition; the wrong disk destroys data." ;;
            tools_browse_title) echo "File browser" ;;
            tools_cwd)          echo "Current directory: " ;;
            tools_nodirs)       echo "(no subdirectories)" ;;
            tools_dir_tag)      echo "[dir]" ;;
            tools_other_a)      echo "This directory has " ;;
            tools_other_b)      echo " more files (not selectable)" ;;
            tools_browse_nav)   echo "digit to enter    U up    P long listing    ESC back" ;;
            tools_list_fail)    echo "Listing failed" ;;
            tools_no_dir_a)     echo "There is no directory " ;;
            tools_no_dir_b)     echo "." ;;
            tools_backup_title) echo "Backup" ;;
            tools_bak1)         echo "1. Back up to the USB stick: " ;;
            tools_bak2)         echo "2. Back up to an SMB share  (not configured on this machine)" ;;
            tools_bak_no)       echo "Cannot back up" ;;
            tools_bak_ro)       echo "USB location is not writable: " ;;
            tools_bak_prompt)   echo "Source path to back up (ESC to cancel): " ;;
            tools_no_path)      echo "Path does not exist: " ;;
            tools_done)         echo "Done." ;;
            tools_smb_title)    echo "SMB backup" ;;
            tools_smb_line)     echo "This version does not implement SMB. You can do it by hand:" ;;
            tools_smb_cmd)      echo "mount -t cifs //server/share /mnt/smb -o username=user,password=pass" ;;
            tools_smb_cp)       echo "cp -av /path/to/backup /mnt/smb/" ;;
            tools_smb_note)     echo "(the 4.0 memory doc also lists SMB as unfinished)" ;;
            tools_check_title)  echo "Self-check / diagnostics" ;;
            tools_net)          echo "Network:" ;;
            tools_none)         echo "  none" ;;
            tools_route)        echo "Default route:" ;;
            tools_iw)           echo "Wireless devices in the kernel:" ;;
            tools_no_iw)        echo "  no iw, or no wireless device" ;;
            tools_sshline_a)    echo "SSH port listening (configured " ;;
            tools_sshline_b)    echo "):" ;;
            tools_no_ss)        echo "  no ss command" ;;
            tools_disk)         echo "Disks:" ;;
            tools_no_lsblk)     echo "  no lsblk" ;;
            tools_lock)         echo "Lock file: " ;;
            tools_exist)        echo "exists" ;;
            tools_absent)       echo "none" ;;
            tools_stopfile)     echo "Stop flag: " ;;
            mon_donefile)        echo "AI finished marker: " ;;
            mon_notice)     echo "Messages from the AI (ai-notice.sh):" ;;
            mon_rootshell)       echo "C enter a root command line" ;;
            mon_ai_online)       echo "AI login: " ;;
            mon_ai_yes)          echo "CONNECTED" ;;
            mon_ai_no)           echo "not connected yet" ;;
            mon_ssh_state)       echo "sshd: " ;;
            mon_ssh_up)          echo "running" ;;
            mon_ssh_down)        echo "NOT running (the AI cannot connect)" ;;
            mon_clear)           echo "X clear the E-stop marker (only when you are sure)" ;;
            tools_donefile)      echo "AI finished marker: " ;;
            tools_estopfile)     echo "E-stop marker: " ;;
            tools_clear)         echo "to clear a marker press 0 in the self-check page" ;;
            tools_log)          echo "Log: " ;;
            tools_conf)         echo "Config: " ;;
            tools_conf_w)       echo "Config writable: " ;;
            tools_yes)          echo "yes" ;;
            tools_no)           echo "no" ;;
            tools_conf_p)       echo "Config persistent: " ;;
            # monitor page (ai-monitor.sh)
            mon_title)        echo "AI monitor" ;;
            mon_sessions)     echo "Current login sessions:" ;;
            mon_none)         echo "  (none)" ;;
            mon_pause)        echo "Pause flag: " ;;
            mon_paused)       echo "paused" ;;
            mon_notpaused)    echo "not paused" ;;
            mon_stop)         echo "E-stop flag: " ;;
            mon_stopped)      echo "stopped" ;;
            mon_notstopped)   echo "not stopped" ;;
            mon_stopfile)     echo "Stop flag file: " ;;
            mon_nav1)         echo "K disconnect the AI session   P pause AI   R resume AI" ;;
            mon_nav2)         echo "L view log       E emergency stop" ;;
            mon_killed_a)     echo "Disconnected " ;;
            mon_killed_b)     echo " session(s)." ;;
            mon_nosession)    echo "No AI SSH session found." ;;
            mon_paused_done)  echo "Paused." ;;
            mon_resumed)      echo "Resumed." ;;
            mon_log_title)    echo "Log: " ;;
            mon_read_fail)    echo "Read failed" ;;
            mon_log_missing)  echo "The log file does not exist yet." ;;
            mon_confirm_stop) echo "Emergency stop: disconnect the sessions and set the E-stop flag?" ;;
            mon_stopped_done) echo "Emergency stop set." ;;
            mon_clear_done)      echo "E-stop marker cleared. The rescue flow works again." ;;
            mon_clear_confirm)   echo "Clear the E-stop marker? Remote access becomes possible again." ;;
            mon_clear_none)      echo "There is no E-stop marker to clear." ;;
            mon_shell_title)     echo "Local root command line" ;;
            mon_shell_hint)      echo "You are root. Type exit to come back to this monitor page." ;;
            common_pw_warning) echo "Do not enter important passwords. Passwords can be easily obtained." ;;
            ssh_nonet) echo "not online" ;;
            ssh_locked_title) echo "SSH is locked" ;;
            ssh_locked_file) echo "Lock file present: " ;;
            ssh_locked_hint) echo "Delete it to enable remote access." ;;
            ssh_not_listening_hint) echo "Use 9.Self-check to see the port, or check journalctl -u ssh." ;;
            rescue_title) echo "AI Rescue Mode" ;;
            rescue_intro1)   echo "It tries several ways to get online; the first success goes to the monitor page." ;;
            rescue_esc_hint) echo "ESC = abort back to the main menu" ;;
            gd_title)                  echo "Guided configuration" ;;
            gd_q1)                     echo "Can you get this machine online by yourself?" ;;
            gd_q1b)                     echo "(without relying on any existing setting)" ;;
            gd_q1_1)                   echo "  1  Yes" ;;
            gd_q1_2)                   echo "  2  No, this machine must help" ;;
            gd_q2)                     echo "Which way will you use?" ;;
            gd_q2_1)                   echo "  1  A network cable" ;;
            gd_q2_2)                   echo "  2  My own WiFi (with a password)" ;;
            gd_q2_3)                   echo "  3  Phone USB sharing" ;;
            gd_q2_4)                   echo "" ;;
            gd_q3)                     echo "What can you use to get this machine online?" ;;
            gd_q3_1)                   echo "  1  A phone that can share a hotspot" ;;
            gd_q3_2)                   echo "  2  Another device that is already online" ;;
            gd_q3_3)                   echo "  3  Neither" ;;
            gd_checking)               echo "Testing the internet..." ;;
            gd_ok)                     echo "ONLINE" ;;
            gd_ok_line)                echo "This machine is online now, so the AI can connect." ;;
            gd_wired_1)                echo "Plug the cable into this machine and the router." ;;
            gd_wired_2)                echo "Getting an address over the cable..." ;;
            gd_wired_fail)             echo "No internet from the cable. Check both ends, or try another way." ;;
            gd_wifi_1)                 echo "Next I scan; pick your WiFi and type its password." ;;
            gd_wifi_fail)              echo "WiFi is up but there is no internet (a login page may be needed)." ;;
            gd_usb_1)                  echo "On the phone: Settings - Hotspot - USB sharing." ;;
            gd_usb_2)                  echo "Waiting for the phone as a network card..." ;;
            gd_usb_fail)               echo "No phone network card. Check the cable and that USB sharing is ON." ;;
            gd_bt_1)                   echo "" ;;
            gd_bt_2)                   echo "" ;;
            gd_bt_3)                   echo "" ;;
            gd_ph_1)                   echo "On your phone, turn on the personal hotspot." ;;
            gd_ph_2)                   echo "Next I scan; pick your phone hotspot and type its password." ;;
            gd_ph_fail)                echo "The phone hotspot did not give internet." ;;
            gd_share_title)            echo "Share another device's internet" ;;
            gd_share_1)                echo "This machine opens its own hotspot." ;;
            gd_share_2)                echo "Join it from the device that is online." ;;
            gd_share_3)                echo "Then turn on sharing there." ;;
            gd_share_confirm)          echo "Open the hotspot now?" ;;
            gd_share_4)                echo "Now on that computer: share its network to this hotspot." ;;
            gd_share_5)                echo "This machine should get an address. Press any key when done." ;;
            gd_share_fail)             echo "Still no internet. Check sharing is on for this hotspot." ;;
            gd_local_title)            echo "No network yet - what still works here" ;;
            gd_local_1)                echo "A network cable is easiest: plug it in, then reboot." ;;
            gd_local_2)                echo "Or move the machine where there is a cable or WiFi." ;;
            gd_local_3)                echo "Other things work without internet: disks, backup, Windows tools." ;;
            gd_local_4)                echo "Manual: ip -br link then dhcpcd <iface> then ip -br addr" ;;
            gd_local_5)                echo "Once online, come back here and the AI can connect." ;;
            ssh_diag_privsep)          echo "Reason: the sshd system user is missing in this image." ;;
            ssh_diag_hostkey)          echo "Reason: no host key yet (ssh-keygen -A has not run)." ;;
            ssh_diag_unknown)          echo "Reason: unknown - see the log / page 9." ;;
            tools_bak_progress)        echo "Backing up... files:" ;;
            tools_bak_esc)             echo "(ESC = cancel)" ;;
            tools_bak_abort)           echo "Stop the backup now? Files already copied are kept." ;;
            tools_bak_cancelled)       echo "Backup CANCELLED by you." ;;
            tools_bak_failed)          echo "Backup FAILED (see the reason above)." ;;
            tools_ssh_yes)             echo "==> sshd IS listening: the AI can connect." ;;
            tools_ssh_no)              echo "==> sshd is NOT listening: the AI cannot connect yet." ;;
            pw_reuse)                  echo "Reusing the password generated earlier this boot:" ;;
            ssh_new_pw)                echo "Press N within 10 seconds to generate a NEW password, or wait to keep this one." ;;
            rescue_auto_mode)          echo "AUTOMATIC RESCUE (no keyboard needed)" ;;
            rescue_auto_hint)          echo "Nothing to press here - it runs by itself. ESC returns to the menu." ;;
            rescue_auto_pick_no)       echo "No key pressed - I will continue as 'cannot operate' in" ;;
            rescue_can_type)           echo "Can you use a keyboard right now?" ;;
            rescue_can_yes)            echo "  1  Yes, I can type (I will ask a few questions)" ;;
            rescue_can_no)             echo "  2  No / only a screen (run fully automatically)" ;;
            rescue_step1)              echo "[1/6]" ;;
            rescue_step2)              echo "[2/6]" ;;
            rescue_step3)              echo "[3/6]" ;;
            rescue_step4)              echo "[4/6]" ;;
            rescue_step5)              echo "[5/6]" ;;
            rescue_step6)              echo "[6/6]" ;;
            rescue_s1_trying)          echo "Reading the config file and trying its network settings..." ;;
            rescue_wired_title)        echo "Wired network (network cable)" ;;
            rescue_wired_trying)       echo "Trying DHCP over the network cable..." ;;
            rescue_wired_fail)         echo "No address from the cable. Check both ends and the router." ;;
            rescue_lastwifi_title)     echo "Last WiFi that worked" ;;
            rescue_lastwifi_fail)      echo "That WiFi is not reachable now." ;;
            rescue_s2_fail_auto)       echo "The phone hotspot did not answer (is it still on?)." ;;
            rescue_s2_pick)            echo "Next I will scan for WiFi; pick your phone's hotspot from the list." ;;
            rescue_s3_starting)        echo "Starting this machine's own hotspot..." ;;
            rescue_s3_join_hint)       echo "Now join this hotspot from your phone or another device." ;;
            rescue_ssh_fail_title)     echo "sshd did NOT start" ;;
            rescue_ssh_fail_l1)        echo "Nothing is listening on port " ;;
            rescue_ssh_fail_l2)        echo "The AI cannot connect yet. See page 9 (self-check) or the log." ;;
            rescue_guided_title)       echo "Which network can you give this machine?" ;;
            rescue_guided_ask)         echo "Pick one - I will do the rest:" ;;
            rescue_guided_1)           echo "  1  A network cable (simplest: just plug it in)" ;;
            rescue_guided_2)           echo "  2  WiFi (I will scan and you type the password)" ;;
            rescue_guided_3)           echo "  3  Phone hotspot (pick it, then type its password)" ;;
            rescue_guided_4)           echo "  4  Let this machine open its own hotspot (another device joins)" ;;
            rescue_guided_5)           echo "  5  None of these (show me what to do locally)" ;;
            rescue_estop_on)           echo "EMERGENCY STOP is active: " ;;
            rescue_estop_how)          echo "The rescue flow is disabled. Clear it on the monitor page (key 0)." ;;
            rescue_s4_manual)          echo "Manual: ip -br link (list NICs) -> dhcpcd <iface> -> ip -br addr" ;;
            rescue_s4_keys)            echo "Or plug in a cable / a phone hotspot and reboot. Logs: page 9, or the monitor page (L)." ;;
            rescue_s4_shell_confirm)   echo "Open a local root command line now?" ;;
            rescue_auto_monitor)   echo "Monitor page in 5 seconds (any key goes now)..." ;;
            rescue_lockfile) echo "A lock file exists; remote access is disabled and rescue is skipped." ;;
            rescue_no_config) echo "No config file; starting from step 2." ;;
            rescue_s1_title) echo "Step 1 | Get online with the config file" ;;
            rescue_s1_skip_auto) echo "auto_config = 0; skipping this step." ;;
            rescue_s1_volatile) echo "Note: no USB config found; this step uses the defaults." ;;
            rescue_s1_config) echo "Config: " ;;
            rescue_s1_try_wifi) echo "Trying the WiFi from the config file: " ;;
            rescue_online) echo "Online." ;;
            rescue_s1_wifi_fail) echo "The configured WiFi did not connect; moving on to the next step." ;;
            rescue_s1_no_ssid) echo "wifi_ssid is not set in the config; skipping WiFi." ;;
            rescue_s1_wifi_off) echo "wifi_auto_connect = 0; skipping WiFi." ;;
            rescue_s1_wired_try) echo "Trying the wired network ..." ;;
            rescue_s1_wired_ok) echo "The wired network is online." ;;
            rescue_s1_wired_fail) echo "The wired network did not connect." ;;
            rescue_s2_title) echo "Step 2 | Phone hotspot" ;;
            rescue_s2_open) echo "Open a hotspot on your phone:" ;;
            rescue_ssid_label) echo "Name: " ;;
            rescue_pass_label) echo "Password: " ;;
            rescue_s2_note) echo "This machine will connect shortly. ESC = abort to the main menu." ;;
            rescue_countdown) echo "countdown" ;;
            rescue_try_connect) echo "Trying to connect to " ;;
            rescue_s2_connected) echo "The phone hotspot is online." ;;
            rescue_s2_retry_a) echo "Not connected yet; retrying in 30 seconds (waited " ;;
            rescue_s2_retry_b) echo " s, up to 600 s)." ;;
            rescue_s2_fail_title) echo "The phone hotspot did not work" ;;
            rescue_s2_retry_enter) echo "ENTER = try again from the beginning" ;;
            rescue_s2_esc) echo "ESC  = abort back to the main menu" ;;
            rescue_s3_title) echo "Step 3 | Start a hotspot on this machine" ;;
            rescue_s3_ask) echo "Let this machine start its own hotspot so other devices can connect?" ;;
            rescue_s3_confirm) echo "Start the local hotspot?" ;;
            rescue_s3_started) echo "The hotspot has started." ;;
            rescue_s3_fail) echo "Start failed: no hostapd and no nmcli." ;;
            rescue_s4_title) echo "Step 4 | Fallback" ;;
            rescue_s4_line1) echo "Earlier steps failed; opening a local command line for manual work." ;;
            rescue_s4_line2) echo "Type exit to return to the main menu." ;;
            net_no_wifi) echo "No wireless interface found." ;;
            net_wpa_conf_fail) echo "Cannot write /tmp/wpa.conf" ;;
            net_no_wpa) echo "wpa_supplicant is not installed; cannot connect to a WPA network." ;;
            net_wpa_fail) echo "wpa_supplicant failed to start." ;;
            net_pass_prompt) echo "Password (ESC to cancel, ENTER for an open network): " ;;
            net_cancelled) echo "Cancelled." ;;
            net_ssid_prompt) echo "SSID (ESC to cancel): " ;;
            net_ssid_empty) echo "SSID is empty; cancelled." ;;
            net_connecting) echo "Connecting to " ;;
            net_connect_ok) echo "Connected." ;;
            net_local_ip) echo "Local IP: " ;;
            net_connect_fail) echo "Connection failed." ;;
            net_troubleshoot) echo "Troubleshooting: check the password, check that it is a 2.4G band, check that the adapter supports it (iw dev)." ;;
            net_no_dnsmasq) echo "(no dnsmasq: give the device a manual address 192.168.66.x/24, gateway 192.168.66.1)" ;;
            net_hotspot_short) echo "The hotspot passphrase is shorter than 8 characters; cannot start: " ;;
            net_hostapd_fail) echo "hostapd failed to start; the last few error lines:" ;;
            net_nmcli_fail) echo "nmcli failed to start the hotspot (its own error is above)." ;;
            net_scanning) echo "Scanning WiFi ..." ;;
            net_iface_label) echo "Wireless interface: " ;;
            net_iface_missing) echo "not found" ;;
            net_ip_label) echo "Current IP : " ;;
            net_ip_offline) echo "not connected" ;;
            net_no_networks) echo "No networks were found." ;;
            net_no_networks_hint) echo "R rescan, M enter an SSID manually." ;;
            net_nav_hint) echo "Number + ENTER to select   M enter SSID manually   R rescan" ;;
            net_no_item_a) echo "There is no item " ;;
            net_no_item_b) echo "." ;;
            net_rescanning) echo "Rescanning ..." ;;
            net_wired_ok) echo "wired is online" ;;
            net_wired_off) echo "wired is not online" ;;
            pw_readonly_note) echo "Note: the password file location is read-only; nothing was written to the USB stick this time." ;;
            pw_no_user_a) echo "User " ;;
            pw_no_user_b) echo " does not exist; cannot set the password." ;;
            pw_chpasswd_fail) echo "chpasswd failed." ;;
            pw_ssh_user) echo "SSH user: " ;;
            pw_usb_found_a) echo "USB password file: found (" ;;
            pw_usb_missing_a) echo "USB password file: missing (" ;;
            pw_usb_suffix) echo ")" ;;
            pw_opt1) echo "1. Use the password on the USB stick" ;;
            pw_opt2) echo "2. Set a new password and use it" ;;
            pw_used_usb) echo "Used the password from the USB stick." ;;
            pw_usb_absent) echo "The USB password file does not exist." ;;
            pw_new_prompt) echo "New password (ESC to cancel): " ;;
            pw_new_applied) echo "The new password is now in effect." ;;
            pw_empty) echo "Empty password; nothing changed." ;;
            pw_new_ssh_prompt) echo "New SSH password (ESC to cancel): " ;;
            pw_cancelled) echo "Cancelled." ;;
            shell_title) echo "Local command line" ;;
            shell_text) echo "This is a root shell. Type exit to return to the main menu." ;;
            shell_exit) echo "Left the command line, back to the main menu." ;;
            menu_confirm_reboot) echo "Reboot?" ;;
            menu_confirm_shutdown) echo "Shut down?" ;;
            pw_title)        echo "4. Password file" ;;
            *)               echo "$key" ;;
        esac
        return 0
    fi
    case "$key" in
        nav_back)        echo "ESC = 返回上一级          X = 同 ESC" ;;
        nav_hint)        echo "ESC/X = 返回      数字 = 选择      ENTER = 重绘" ;;
        menu_countdown)  echo "急救倒计时" ;;
        menu_anykey)     echo "按任意键取消" ;;
        menu_overall)    echo "-- 整体配置 --" ;;
        menu_individual) echo "-- 单独配置 --" ;;
        menu_settings)   echo "-- 设置 --" ;;
        menu_system)               echo "-- 系统（重启/关机）--" ;;
        menu_a)          echo "A. 急救模式" ;;
        menu_b)          echo "B. 引导配置" ;;
        menu_c)          echo "C. 自动配置" ;;
        menu_d)          echo "D. 自动保存" ;;
        menu_e)          echo "E. 编辑配置文件" ;;
        menu_f)          echo "F. 默认配置" ;;
        menu_g)          echo "G. U 盘配置文件" ;;
        menu_h)          echo "H. 帮助" ;;
        menu_l)          echo "L. 语言" ;;
        menu_r)          echo "R. 重启" ;;
        menu_s)          echo "S. 关机" ;;
        menu_1)          echo "1. SSH" ;;
        menu_2)          echo "2. WiFi / 刷新" ;;
        menu_3)          echo "3. 密码文件" ;;
        menu_4)          echo "4. 命令行" ;;
        menu_5)          echo "5. Windows 工具" ;;
        menu_6)          echo "6. 文件浏览" ;;
        menu_7)          echo "7. 备份到共享" ;;
        menu_8)          echo "8. 自检" ;;
        menu_9)          echo "" ;;
        menu_nav1)       echo "ESC / X : 退出到命令行      L : 语言" ;;
        menu_nav2)       echo "数字 : 选择      ENTER : 重绘" ;;
        menu_readonly)   echo "!! 配置只读：" ;;
        menu_volatile)   echo "!! 没找到 U 盘：配置在内存" ;;
        exit_title)      echo "退出 AI-Boot 主菜单" ;;
        exit_line1)      echo "退出后拿到一个本机 root 命令行。" ;;
        exit_line2)      echo "在命令行里输入 exit 会自动回到这个菜单。" ;;
        exit_confirm)    echo "确定退出到命令行？" ;;
        ssh_title)       echo "SSH 连接卡" ;;
        ssh_ip)          echo "IP 地址" ;;
        ssh_port)        echo "端口" ;;
        ssh_user)        echo "用户" ;;
        ssh_cmd)         echo "连接命令" ;;
        ssh_pw)          echo "密码" ;;
        ssh_root_same)   echo "root 密码与它相同" ;;
        ssh_readme)      echo "登录后先读" ;;
        ssh_not_listening) echo "警告：SSH 端口上没有在监听。" ;;
        # shared
        press_any) echo "按任意键继续（ESC 返回上一级）..." ;;
        common_esc_abort)          echo "  (ESC 中止)" ;;
        common_cancelled)          echo "-- 已取消" ;;
        common_timeout_cancel)     echo "-- 超时，按取消处理" ;;
        common_yn_hint)            echo "(请输入 Y 或 N)" ;;
        common_confirm_default)    echo "确定吗？" ;;
        cfg_write_readonly)        echo "配置位置只读，未写回：" ;;
        warn_readonly)             echo "$(t warn_readonly)" ;;
        warn_volatile)             echo "$(t warn_volatile)" ;;
        warn_where)                echo "      位置：" ;;
        # config page (ai-config.sh)
        cfg_where_title)           echo "配置文件位置" ;;
        cfg_path)                  echo "路径：" ;;
        cfg_ro_title)            echo "这个位置是只读的" ;;
        cfg_ro_line)             echo "改动无法保存到：" ;;
        cfg_save_nano)           echo "  存盘：Ctrl+O 再回车。  退出：Ctrl+X。" ;;
        cfg_save_vi)             echo "  存盘退出：按 Esc，输入 :wq 再回车。  不保存退出：按 Esc 再输入 :q!" ;;
        cfg_toggle_same)         echo "没有改动。" ;;
        cfg_unsaved_confirm)     echo "不写回就离开吗？" ;;
        cfg_reload_confirm)      echo "要从文件重读、放弃未保存的改动吗？" ;;
        cfg_reset_confirm2)      echo "这会重写整个文件，不能恢复：" ;;
        cfg_on)                  echo "开(1)" ;;
        cfg_off)                 echo "关(0)" ;;
        cfg_source)              echo "来源：" ;;
        cfg_source_file)         echo "磁盘上的配置文件" ;;
        cfg_source_mem)          echo "内存里的默认值（还没有配置文件）" ;;
        cfg_howto_t1)            echo "想让它开机自动生效：把 ai-boot.conf 放到 U 盘上" ;;
        cfg_howto_t2)            echo "  <U盘>/AI-Boot/ai-boot.conf  （或直接放 U 盘里）" ;;
        cfg_howto_t3)            echo "没有文件时用的是内置默认值，改动重启就没了。" ;;
        cfg_howto_keys)          echo "按键：E 逐项编辑   G 编辑原始文件   ESC 返回" ;;
        cfg_pick_title)          echo "配置写到哪个位置？" ;;
        cfg_pick_mem)            echo "只放内存（/run/ai-boot，重启就没了）" ;;
        cfg_pick_hint)           echo "输入序号后按回车。ESC 取消。" ;;
        cfg_pick_current)        echo "当前选中：" ;;
        cfg_pick_use_this)       echo "就写到这里吗？" ;;
        cfg_pick_cancel)         echo "没有选择位置。" ;;
        cfg_nolabel)             echo "（无名）" ;;
        cfg_free)                echo "可用" ;;
        cfg_mount)               echo "挂载点：" ;;
        cfg_create_title)        echo "还没有配置文件" ;;
        cfg_create_ask)          echo "要现在写入吗？会写到：" ;;
        cfg_create_confirm)      echo "要写入配置文件吗？" ;;
        cfg_create_skip)         echo "没有写入，改动只在内存里，重启就没了。" ;;
        cfg_create_fail)         echo "写入失败（盘是只读的？）。" ;;
        cfg_unsaved_warn)        echo "你有改动还没有写进文件。" ;;
        cfg_unsaved_write)       echo "S 现在写回" ;;
        cfg_unsaved_drop)        echo "ESC/X 放弃改动并离开" ;;
        cfg_invalid_bool)        echo "请输入 1 或 0（1 = 开，0 = 关）。" ;;
        cfg_invalid_port)        echo "请输入 1 到 65535 之间的端口号。" ;;
        cfg_invalid_level)       echo "请输入 info、debug、warn 或 error 之一。" ;;
        cfg_saved_mem)           echo "只改了内存（自动保存已关，或还没有文件）" ;;
        cfg_toggle_hint)         echo "按 1 设为开、按 0 设为关、ESC 保持原样。" ;;
        cfg_guide_help1)         echo "用法：在 U 盘上放一个文本文件 guide.txt" ;;
        cfg_guide_help2)         echo "  <U盘>/AI-Boot/guide.txt   这里只是看，不会执行。" ;;
        cfg_writable_yes)          echo "可写：是" ;;
        cfg_writable_no)           echo "可写：否（改动不会保存！）" ;;
        cfg_persist_no)            echo "持久：否（在内存里，重启就没了）" ;;
        cfg_persist_reason)        echo "原因：没找到 U 盘上的 AI-Boot 目录" ;;
        cfg_persist_yes)           echo "持久：是（在 U 盘上）" ;;
        cfg_usb_mount)             echo "U 盘挂载点：" ;;
        cfg_current_list)          echo "当前生效的配置（含默认值）：" ;;
        cfg_default_title)         echo "默认配置" ;;
        cfg_default_note)          echo "下面这些值会在没有配置文件、或按 D 重置时生效：" ;;
        cfg_guide_title)           echo "引导配置（急救顺序）" ;;
        cfg_guide_s1)              echo "第 1 步：读本配置联网（需要 auto_config=1）" ;;
        cfg_guide_s2)              echo "第 2 步：有线 DHCP" ;;
        cfg_guide_s3)              echo "第 3 步：手机热点" ;;
        cfg_guide_s4)              echo "第 4 步：本机热点" ;;
        cfg_guide_s5)              echo "第 5 步：兜底掉到本地命令行" ;;
        cfg_guide_note)            echo "每一步失败都会回滚到下一步，不会卡住。" ;;
        cfg_guidefile_title)       echo "引导文件" ;;
        cfg_file_missing)          echo "文件不存在：" ;;
        cfg_file_label)            echo "文件：" ;;
        cfg_guide_read_confirm)    echo "读取这个引导文件？" ;;
        cfg_read_fail)             echo "读取失败" ;;
        cfg_edit_title)            echo "修改" ;;
        cfg_desc)                  echo "说明：" ;;
        cfg_cur)                   echo "当前：" ;;
        cfg_secret_cur_pre)        echo "当前：********（" ;;
        cfg_secret_cur_suf)        echo " 位）" ;;
        cfg_empty)                 echo "（空）" ;;
        cfg_edit_hint)             echo "回车=不改    - =清空    ESC=取消" ;;
        cfg_newval)                echo "新值: " ;;
        cfg_saved)                 echo "已保存：" ;;
        cfg_save_fail)             echo "写入失败（位置只读？）：" ;;
        cfg_edit_list_title)       echo "逐项编辑（输入序号后按回车）" ;;
        cfg_edit_keys)             echo "S 立即写回   R 重读   D 恢复默认   W 这个文件怎么用" ;;
        cfg_no_item_a)             echo "没有第 " ;;
        cfg_no_item_b)             echo " 项。" ;;
        cfg_written)               echo "已写回：" ;;
        cfg_write_fail)            echo "写回失败。" ;;
        cfg_reloaded)              echo "已重新读取。" ;;
        cfg_reset_confirm)         echo "把所有键恢复成默认值？" ;;
        cfg_reset_done)            echo "已恢复默认值。" ;;
        cfg_no_editor_title)       echo "没有可用的编辑器" ;;
        cfg_no_editor_l1)          echo "本系统里没有 nano / vim / vi。" ;;
        cfg_no_editor_l2)          echo "改用逐项编辑，功能一样，不会把文件改坏。" ;;
        cfg_open_a)                echo "用 " ;;
        cfg_open_b)                echo " 打开：" ;;
        cfg_editor_hint)           echo "（存盘退出后按任意键回到菜单）" ;;
        cfg_editor_fail)           echo "启动失败，改用逐项编辑。" ;;
        cfg_old)                   echo "原值：" ;;
        cfg_new)                   echo "   新值：" ;;
        cfg_toggle_saved)          echo "已保存" ;;
        cfg_toggle_mem)            echo "只在内存里（位置只读）" ;;
        cfg_lang_title)            echo "语言 / Language" ;;
        cfg_lang_zh)               echo "2. 中文（主界面与公共提示）" ;;
        cfg_switched_en)           echo "已切换为 English。" ;;
        cfg_switched_zh)           echo "已切换为中文（部分界面还是英文，见发布说明）。" ;;
        cfg_name_autocfg)          echo "Auto config 总开关" ;;
        cfg_name_autosave)         echo "Auto save 总开关" ;;
        cfg_lbl_auto_config)       echo "急救模式读取本配置的总开关 0/1" ;;
        cfg_lbl_auto_save)         echo "改动后是否自动写回本文件 0/1" ;;
        cfg_lbl_lang)              echo "界面语言 en/zh" ;;
        cfg_lbl_wifi_auto_connect) echo "急救阶段是否用下面 SSID 自动联网 0/1" ;;
        cfg_lbl_wifi_ssid)         echo "自动连接用的 WiFi 名称" ;;
        cfg_lbl_wifi_password)     echo "自动连接用的 WiFi 密码" ;;
        cfg_lbl_wired_dhcp)        echo "是否尝试有线 DHCP 0/1" ;;
        cfg_lbl_static_ip)         echo "静态 IP（留空=用 DHCP）" ;;
        cfg_lbl_static_mask)       echo "静态掩码 24 或 255.255.255.0" ;;
        cfg_lbl_static_gateway)    echo "静态网关" ;;
        cfg_lbl_static_dns)        echo "静态 DNS" ;;
        cfg_lbl_hotspot_enabled)   echo "急救阶段是否启用手机热点环节 0/1" ;;
        cfg_lbl_hotspot_ssid)      echo "本机热点名称（留空=随机）" ;;
        cfg_lbl_hotspot_password)  echo "本机热点密码（留空=随机）" ;;
        cfg_lbl_phone_hotspot_ssid)     echo "手机热点名称（全自动急救用；留空=跳过）" ;;
        cfg_lbl_phone_hotspot_password) echo "手机热点密码（全自动急救用）" ;;
        cfg_lbl_ai_user)           echo "SSH 允许登录的用户名" ;;
        cfg_lbl_ai_done_file)      echo "AI 完工标记（AI 做完时自己写入）" ;;
        cfg_lbl_ai_estop_file)     echo "人工急停标记（只有人能设置）" ;;
        cfg_lbl_ssh_port)          echo "SSH 端口" ;;
        cfg_lbl_ssh_allow_root)    echo "是否允许 root 直接 SSH 登录 0/1" ;;
        cfg_lbl_log_level)         echo "日志级别 info/debug" ;;
        cfg_lbl_log_save_usb)      echo "日志是否写到 U 盘 0/1" ;;
        # help page (ai-help.sh)
        help_title)      echo "帮助  AI-Boot" ;;
        help_keys_title) echo "按键约定（全系统一致）：" ;;
        help_k1)         echo "  ESC  返回上一级（任何界面都是按一下就返回）" ;;
        help_k2)         echo "  X    与 ESC 一样，沿用 4.0" ;;
        help_k3)         echo "  数字 直接选择对应序号后按回车" ;;
        help_k4)         echo "  回车 确认 / 重绘当前界面" ;;
            help_k5)        echo "   L    切换语言（英文 / 中文）" ;;
        help_menu_title) echo "主菜单各功能：" ;;
        help_m1)         echo "  A 说明   B 引导文件   C 自动配置   D 自动保存" ;;
        help_m2)         echo "  E 编辑配置   F 默认配置   G 原始配置文件" ;;
        help_m3)         echo "  1 SSH   2 WiFi   3 急救   4 密码   5 命令行" ;;
        help_m4)         echo "  6 Windows 工具   7 文件浏览   8 备份   9 自检" ;;
        help_m5)         echo "  L 语言   R 重启   S 关机" ;;
        help_cfg)        echo "配置文件：" ;;
        help_note1)      echo "默认 SSH 用户由 ai_user 决定（默认 ai），密码每次开机随机。" ;;
        help_note2)      echo "登录后先读 /usr/local/share/ai-boot/AI-README.txt。" ;;
        # tools page (ai-tools.sh)
        tools_win_title)    echo "Windows 工具" ;;
        tools_w1)           echo "1. 列出磁盘 / 分区" ;;
        tools_w2)           echo "2. 挂载 Windows 分区" ;;
        tools_w3)           echo "3. 修复 Windows 引导        （仅给出提示）" ;;
        tools_w4)           echo "4. 备份 Windows 文件        （仅给出提示）" ;;
        tools_w5)           echo "5. 把 Windows ISO 写入 U 盘 （仅给出提示）" ;;
        tools_disk_title)   echo "磁盘 / 分区" ;;
        tools_nolsblk)      echo "lsblk 不可用" ;;
        tools_mnt_title)    echo "挂载 Windows 分区" ;;
        tools_mnt_ex)       echo "写成：/dev/sda2" ;;
        tools_mnt_prompt)   echo "分区（ESC 取消）: " ;;
        tools_mnt_ok)       echo "已挂载到 /mnt/win" ;;
        tools_mnt_fail)     echo "挂载失败。可能原因：" ;;
        tools_mnt_r1)       echo "  - 分区名不对（用 1 先看）" ;;
        tools_mnt_r2)       echo "  - NTFS 处于休眠脏状态（先在 Windows 里完全关机）" ;;
        tools_mnt_r3)       echo "  - 需要 ntfs-3g：" ;;
        tools_fix_title)    echo "修复 Windows 引导（仅提示）" ;;
        tools_fix_line)     echo "本版本没有实现自动修复，需要你手工执行：" ;;
        tools_fix_s1)       echo "1) 先在 Windows 里：" ;;
        tools_fix_s2)       echo "   （S: 是 EFI 分区盘符）" ;;
        tools_fix_s3)       echo "2) 或在 Linux 里：" ;;
        tools_fix_s5)       echo "   sudo fdisk -l   # 找到 EFI 分区" ;;
        tools_fix_s7a)      echo "   确认 " ;;
        tools_fix_s7b)      echo " 存在" ;;
        tools_bak_title)    echo "备份 Windows 文件（仅提示）" ;;
        tools_bak_line)     echo "先用 2 挂载，然后手工：" ;;
        tools_iso_title)    echo "写入 Windows ISO（仅提示）" ;;
        tools_iso_line)     echo "这一步会清空目标盘，本版本不代做。命令模板：" ;;
        tools_iso_s1)       echo "lsblk                                  # 先确认盘符" ;;
        tools_iso_warn)     echo "注意：of= 指向设备而不是分区，写错盘会毁数据。" ;;
        tools_browse_title) echo "文件浏览" ;;
        tools_cwd)          echo "当前目录：" ;;
        tools_nodirs)       echo "（没有子目录）" ;;
        tools_dir_tag)      echo "[目录]" ;;
        tools_other_a)      echo "本目录另有 " ;;
        tools_other_b)      echo " 个文件（不参与选择）" ;;
        tools_browse_nav)   echo "输入序号进入    U 回上级    P 详细列举    ESC 返回" ;;
        tools_list_fail)    echo "列举失败" ;;
        tools_no_dir_a)     echo "没有第 " ;;
        tools_no_dir_b)     echo " 个目录。" ;;
        tools_backup_title) echo "备份" ;;
        tools_bak1)         echo "1. 备份到 U 盘：" ;;
        tools_bak2)         echo "2. 备份到 SMB 共享  （本机未配置）" ;;
        tools_bak_no)       echo "无法备份" ;;
        tools_bak_ro)       echo "U 盘位置不可写：" ;;
        tools_bak_prompt)   echo "要备份的源路径（ESC 取消）: " ;;
        tools_no_path)      echo "路径不存在：" ;;
        tools_done)         echo "完成。" ;;
        tools_smb_title)    echo "SMB 备份" ;;
        tools_smb_line)     echo "本版本没有实现 SMB。可以手工：" ;;
        tools_smb_cmd)      echo "mount -t cifs //服务器/共享 /mnt/smb -o username=用户,password=密码" ;;
        tools_smb_cp)       echo "cp -av /要备份的路径 /mnt/smb/" ;;
        tools_smb_note)     echo "（4.0 的记忆文档里也把 SMB 列为未完成项）" ;;
        tools_check_title)  echo "自检 / 诊断" ;;
        tools_net)          echo "网络：" ;;
        tools_none)         echo "  无" ;;
        tools_route)        echo "默认路由：" ;;
        tools_iw)           echo "内核无线网卡：" ;;
        tools_no_iw)        echo "  没有 iw 或没有网卡" ;;
        tools_sshline_a)    echo "SSH 端口监听（配置值 " ;;
        tools_sshline_b)    echo "）：" ;;
        tools_no_ss)        echo "  没有 ss" ;;
        tools_disk)         echo "磁盘：" ;;
        tools_no_lsblk)     echo "  无 lsblk" ;;
        tools_lock)         echo "锁定文件：" ;;
        tools_exist)        echo "存在" ;;
        tools_absent)       echo "无" ;;
        tools_stopfile)     echo "停止标记：" ;;
        mon_donefile)        echo "AI 完工标记：" ;;
        mon_notice)     echo "AI 的留言（ai-notice.sh）：" ;;
        mon_rootshell)       echo "C 以 root 进入命令行" ;;
        mon_ai_online)       echo "AI 登录状态：" ;;
        mon_ai_yes)          echo "已连接" ;;
        mon_ai_no)           echo "还没有连上" ;;
        mon_ssh_state)       echo "sshd：" ;;
        mon_ssh_up)          echo "运行中" ;;
        mon_ssh_down)        echo "没有运行（AI 连不进来）" ;;
        mon_clear)           echo "X 清除急停标记（确认安全后再用）" ;;
        tools_donefile)      echo "AI 完工标记：" ;;
        tools_estopfile)     echo "急停标记：" ;;
        tools_clear)         echo "清除标记：在自检页按 0 可清除急停标记" ;;
        tools_log)          echo "日志：" ;;
        tools_conf)         echo "配置：" ;;
        tools_conf_w)       echo "配置可写：" ;;
        tools_yes)          echo "是" ;;
        tools_no)           echo "否" ;;
        tools_conf_p)       echo "配置持久：" ;;
        # monitor page (ai-monitor.sh)
        mon_title)        echo "AI 监视页" ;;
        mon_sessions)     echo "当前登录会话：" ;;
        mon_none)         echo "  （无）" ;;
        mon_pause)        echo "暂停标记：" ;;
        mon_paused)       echo "已暂停" ;;
        mon_notpaused)    echo "未暂停" ;;
        mon_stop)         echo "急停标记：" ;;
        mon_stopped)      echo "已急停" ;;
        mon_notstopped)   echo "未急停" ;;
        mon_stopfile)     echo "停止标记：" ;;
        mon_nav1)         echo "K 断开 AI 会话   P 暂停 AI   R 恢复 AI" ;;
        mon_nav2)         echo "L 查看日志       E 紧急停止" ;;
        mon_killed_a)     echo "已断开 " ;;
        mon_killed_b)     echo " 个会话。" ;;
        mon_nosession)    echo "没有找到 AI 的 SSH 会话。" ;;
        mon_paused_done)  echo "已暂停。" ;;
        mon_resumed)      echo "已恢复。" ;;
        mon_log_title)    echo "日志：" ;;
        mon_read_fail)    echo "读取失败" ;;
        mon_log_missing)  echo "日志文件还不存在。" ;;
        mon_confirm_stop) echo "紧急停止：断开会话并打急停标记？" ;;
        mon_stopped_done) echo "已急停。" ;;
        mon_clear_done)      echo "急停标记已清除，急救可以再用。" ;;
        mon_clear_confirm)   echo "要清除急停标记吗？清除后远程可以再连。" ;;
        mon_clear_none)      echo "现在没有急停标记，不需要清除。" ;;
        mon_shell_title)     echo "本地 root 命令行" ;;
        mon_shell_hint)      echo "当前是 root。输入 exit 回到本监视页。" ;;
        common_pw_warning) echo "请勿输入重要密码，密码可以被轻松获取。" ;;
        ssh_nonet) echo "未联网" ;;
        ssh_locked_title) echo "SSH 已锁定" ;;
        ssh_locked_file) echo "存在锁定文件：" ;;
        ssh_locked_hint) echo "删除它才能开启远程访问。" ;;
        ssh_not_listening_hint) echo "可以用 9.Self-check 看端口，或看 journalctl -u ssh。" ;;
        rescue_title) echo "AI 急救模式" ;;
        rescue_intro1)   echo "会自动依次尝试联网；哪一步成功就进监视页。" ;;
        rescue_esc_hint) echo "ESC = 中止回主菜单" ;;
        gd_title)                  echo "引导配置" ;;
        gd_q1)                     echo "你能自主连接到互联网吗？" ;;
        gd_q1b)                     echo "（不依赖于现有设置）" ;;
        gd_q1_1)                   echo "  1  能" ;;
        gd_q1_2)                   echo "  2  不能，让本机来" ;;
        gd_q2)                     echo "你要用哪种？" ;;
        gd_q2_1)                   echo "  1  有线网线" ;;
        gd_q2_2)                   echo "  2  自己的 WiFi（有密码）" ;;
        gd_q2_3)                   echo "  3  手机 USB 共享" ;;
        gd_q2_4)                   echo "" ;;
        gd_q3)                     echo "你能用哪样给本机上网？" ;;
        gd_q3_1)                   echo "  1  有手机能开热点" ;;
        gd_q3_2)                   echo "  2  有已能上网的另一台" ;;
        gd_q3_3)                   echo "  3  都没有" ;;
        gd_checking)               echo "正在试能否上网…" ;;
        gd_ok)                     echo "联网成功" ;;
        gd_ok_line)                echo "本机已能上网，AI 可以连进来。" ;;
        gd_wired_1)                echo "网线两头接好：本机和路由器。" ;;
        gd_wired_2)                echo "正从网线取地址…" ;;
        gd_wired_fail)             echo "网线没能上网。查两头，或换一种。" ;;
        gd_wifi_1)                 echo "下一步扫描：选中你的 WiFi 并输密码。" ;;
        gd_wifi_fail)              echo "WiFi 已连，不能上网（可能要网页登录）。" ;;
        gd_usb_1)                  echo "手机上：设置 - 热点 - USB 共享。" ;;
        gd_usb_2)                  echo "等手机以网卡出现…" ;;
        gd_usb_fail)               echo "没出现手机网卡。查数据线和 USB 共享。" ;;
        gd_bt_1)                   echo "" ;;
        gd_bt_2)                   echo "" ;;
        gd_bt_3)                   echo "" ;;
        gd_ph_1)                   echo "请在手机上打开个人热点。" ;;
        gd_ph_2)                   echo "下一步扫描：选中手机热点并输密码。" ;;
        gd_ph_fail)                echo "手机热点没能上网。" ;;
        gd_share_title)            echo "共用另一台的网络" ;;
        gd_share_1)                echo "本机自己开一个热点。" ;;
        gd_share_2)                echo "用那台已上网的连上它。" ;;
        gd_share_3)                echo "然后在那台上打开共享。" ;;
        gd_share_confirm)          echo "现在开热点吗？" ;;
        gd_share_4)                echo "现在在那台上：把网共享到这个热点。" ;;
        gd_share_5)                echo "本机应会自动取到地址。好了按任意键。" ;;
        gd_share_fail)             echo "还是没网。查那台是否已共享。" ;;
        gd_local_title)            echo "暂时没网 —— 这里还能用" ;;
        gd_local_1)                echo "网线最好用：接好后重启。" ;;
        gd_local_2)                echo "或换个有网线/WiFi 的位置。" ;;
        gd_local_3)                echo "其它不需要网也能用：看盘、备份、Windows 工具。" ;;
        gd_local_4)                echo "手动：ip -br link 再看 dhcpcd <网卡> 再看 ip -br addr" ;;
        gd_local_5)                echo "连上后回到这里，AI 就能连进来。" ;;
        ssh_diag_privsep)          echo "原因：这个镜像里缺 sshd 系统用户。" ;;
        ssh_diag_hostkey)          echo "原因：还没有主机密钥（ssh-keygen -A 没跑过）。" ;;
        ssh_diag_unknown)          echo "原因：未知 —— 请看日志或 9.自检。" ;;
        tools_bak_progress)        echo "正在备份... 已复制文件数：" ;;
        tools_bak_esc)             echo "（ESC = 取消）" ;;
        tools_bak_abort)           echo "现在停止备份？已经复制过去的会保留。" ;;
        tools_bak_cancelled)       echo "备份已被你取消。" ;;
        tools_bak_failed)          echo "备份失败（原因见上面）。" ;;
        tools_ssh_yes)             echo "==> sshd 正在监听：AI 可以连进来。" ;;
        tools_ssh_no)              echo "==> sshd 没有在监听：AI 现在还连不进来。" ;;
        pw_reuse)                  echo "继续使用本次开机的密码：" ;;
        ssh_new_pw)                echo "10 秒内按 N 可以重新生成密码，不按就继续用现在这个。" ;;
        rescue_auto_mode)          echo "全自动急救（不需要键盘）" ;;
        rescue_auto_hint)          echo "这一屏不需要按任何键，它会自己往下走。按 ESC 返回主菜单。" ;;
        rescue_auto_pick_no)       echo "没有按键，将按 不能按键 继续，还有" ;;
        rescue_can_type)           echo "现在能用键盘吗？" ;;
        rescue_can_yes)            echo "  1  能，可以打字（会问你几句）" ;;
        rescue_can_no)             echo "  2  不能 / 没人按键（请全自动运行）" ;;
        rescue_step1)              echo "[1/6]" ;;
        rescue_step2)              echo "[2/6]" ;;
        rescue_step3)              echo "[3/6]" ;;
        rescue_step4)              echo "[4/6]" ;;
        rescue_step5)              echo "[5/6]" ;;
        rescue_step6)              echo "[6/6]" ;;
        rescue_s1_trying)          echo "正在读配置文件，并尝试里面写的网络…" ;;
        rescue_wired_title)        echo "有线网络（网线）" ;;
        rescue_wired_trying)       echo "正在通过网线获取地址（DHCP）…" ;;
        rescue_wired_fail)         echo "网线没拿到地址。检查两头和路由器。" ;;
        rescue_lastwifi_title)     echo "上次连成功过的 WiFi" ;;
        rescue_lastwifi_fail)      echo "这个 WiFi 现在连不上。" ;;
        rescue_s2_fail_auto)       echo "手机热点连不上（还开着吗？）。" ;;
        rescue_s2_pick)            echo "接下来扫描 WiFi，请从列表里选中你手机的热点。" ;;
        rescue_s3_starting)        echo "正在让本机自己开热点…" ;;
        rescue_s3_join_hint)       echo "现在用你的手机或另一台设备连上这个热点。" ;;
        rescue_ssh_fail_title)     echo "sshd 没有启动" ;;
        rescue_ssh_fail_l1)        echo "端口上没有在监听：" ;;
        rescue_ssh_fail_l2)        echo "AI 现在还连不进来。请看 9.自检 或监视页的日志。" ;;
        rescue_guided_title)       echo "你的网络是哪种？" ;;
        rescue_guided_ask)         echo "选一个，其余自动完成：" ;;
        rescue_guided_1)           echo "  1  有网线（先试这个）" ;;
        rescue_guided_2)           echo "  2  有 WiFi（会扫描，你输密码）" ;;
        rescue_guided_3)           echo "  3  手机热点（选出来，再输密码）" ;;
        rescue_guided_4)           echo "  4  让本机自己开热点（另一台设备来连）" ;;
        rescue_guided_5)           echo "  5  都没有（看本地怎么手动处理）" ;;
        rescue_estop_on)           echo "急停标记正在生效：" ;;
        rescue_estop_how)          echo "急救已被禁用。请在监视页按 0 清除它。" ;;
        rescue_s4_manual)          echo "手动：ip -br link 看网卡 -> dhcpcd <网卡> -> ip -br addr 看地址" ;;
        rescue_s4_keys)            echo "或者接网线/手机热点后重启。日志：9.自检 或监视页按 L。" ;;
        rescue_s4_shell_confirm)   echo "现在进入本地 root 命令行吗？" ;;
        rescue_auto_monitor)   echo "5 秒后自动进入监视页（按任意键立即进入）..." ;;
        rescue_lockfile) echo "存在锁定文件，远程访问被禁用，急救跳过。" ;;
        rescue_no_config) echo "没有配置文件，从第 2 步开始。" ;;
        rescue_s1_title) echo "第 1 步 | 用配置文件联网" ;;
        rescue_s1_skip_auto) echo "auto_config = 0，跳过本步。" ;;
        rescue_s1_volatile) echo "提示：没找到 U 盘配置，本步用的是默认值。" ;;
        rescue_s1_config) echo "配置：" ;;
        rescue_s1_try_wifi) echo "尝试配置文件里的 WiFi：" ;;
        rescue_online) echo "已连通。" ;;
        rescue_s1_wifi_fail) echo "配置 WiFi 没连上，继续下一步。" ;;
        rescue_s1_no_ssid) echo "配置里没写 wifi_ssid，跳过 WiFi。" ;;
        rescue_s1_wifi_off) echo "wifi_auto_connect = 0，跳过 WiFi。" ;;
        rescue_s1_wired_try) echo "尝试有线网络 ..." ;;
        rescue_s1_wired_ok) echo "有线已连通。" ;;
        rescue_s1_wired_fail) echo "有线没连通。" ;;
        rescue_s2_title) echo "第 2 步 | 手机热点" ;;
        rescue_s2_open) echo "请用手机开一个热点：" ;;
        rescue_ssid_label) echo "名称：" ;;
        rescue_pass_label) echo "密码：" ;;
        rescue_s2_note) echo "本机稍后会自动去连它。ESC = 中止回主菜单。" ;;
        rescue_countdown) echo "倒计时" ;;
        rescue_try_connect) echo "尝试连接 " ;;
        rescue_s2_connected) echo "手机热点已连通。" ;;
        rescue_s2_retry_a) echo "还没连上，30 秒后再试（已等 " ;;
        rescue_s2_retry_b) echo " 秒，最多 600 秒）。" ;;
        rescue_s2_fail_title) echo "手机热点没成功" ;;
        rescue_s2_retry_enter) echo "回车 = 从头再试" ;;
        rescue_s2_esc) echo "ESC  = 中止回主菜单" ;;
        rescue_s3_title) echo "第 3 步 | 本机开热点" ;;
        rescue_s3_ask) echo "要让这台机器自己开热点，好让别的设备连上来吗？" ;;
        rescue_s3_confirm) echo "开启本机热点？" ;;
        rescue_s3_started) echo "热点已启动。" ;;
        rescue_s3_fail) echo "启动失败：没有 hostapd，也没有 nmcli。" ;;
        rescue_s4_title) echo "第 4 步 | 兜底" ;;
        rescue_s4_line1) echo "前几步都没成功，进入本地命令行手工处理。" ;;
        rescue_s4_line2) echo "输入 exit 回到主菜单。" ;;
        net_no_wifi) echo "没有找到无线网卡。" ;;
        net_wpa_conf_fail) echo "无法写入 /tmp/wpa.conf" ;;
        net_no_wpa) echo "wpa_supplicant 未安装，无法连接 WPA 网络。" ;;
        net_wpa_fail) echo "wpa_supplicant 启动失败。" ;;
        net_pass_prompt) echo "密码（ESC 取消，开放网络直接回车）: " ;;
        net_cancelled) echo "已取消。" ;;
        net_ssid_prompt) echo "SSID（ESC 取消）: " ;;
        net_ssid_empty) echo "SSID 为空，已取消。" ;;
        net_connecting) echo "正在连接 " ;;
        net_connect_ok) echo "连接成功。" ;;
        net_local_ip) echo "本机 IP: " ;;
        net_connect_fail) echo "连接失败。" ;;
        net_troubleshoot) echo "排错：确认密码、确认是 2.4G 频段、确认网卡支持（iw dev）。" ;;
        net_no_dnsmasq) echo "（没有 dnsmasq：给设备手动配 192.168.66.x/24，网关 192.168.66.1）" ;;
        net_hotspot_short) echo "热点口令少于 8 位，无法启动：" ;;
        net_hostapd_fail) echo "hostapd 启动失败，最后几行错误：" ;;
        net_nmcli_fail) echo "nmcli 启动热点失败（上面是它自己的报错）。" ;;
        net_scanning) echo "正在扫描 WiFi ..." ;;
        net_iface_label) echo "无线网卡: " ;;
        net_iface_missing) echo "未找到" ;;
        net_ip_label) echo "当前 IP : " ;;
        net_ip_offline) echo "未连接" ;;
        net_no_networks) echo "没有扫描到任何网络。" ;;
        net_no_networks_hint) echo "R 重新扫描，M 手动输入 SSID。" ;;
        net_nav_hint) echo "输入序号选择网络后按回车   M 手动输入 SSID   R 重新扫描" ;;
        net_no_item_a) echo "没有第 " ;;
        net_no_item_b) echo " 项。" ;;
        net_rescanning) echo "重新扫描 ..." ;;
        net_wired_ok) echo "有线已连通" ;;
        net_wired_off) echo "有线未连通" ;;
        pw_readonly_note) echo "提示：密码文件位置只读，本次没有写入 U 盘。" ;;
        pw_no_user_a) echo "用户 " ;;
        pw_no_user_b) echo " 不存在，无法设置密码。" ;;
        pw_chpasswd_fail) echo "chpasswd 失败。" ;;
        pw_ssh_user) echo "SSH 用户：" ;;
        pw_usb_found_a) echo "U 盘密码文件：已找到（" ;;
        pw_usb_missing_a) echo "U 盘密码文件：没有（" ;;
        pw_usb_suffix) echo "）" ;;
        pw_opt1) echo "1. 用 U 盘里的密码" ;;
        pw_opt2) echo "2. 设置新密码，并使用它" ;;
        pw_used_usb) echo "已使用 U 盘里的密码。" ;;
        pw_usb_absent) echo "U 盘密码文件不存在。" ;;
        pw_new_prompt) echo "输入新密码（ESC 取消）: " ;;
        pw_new_applied) echo "新密码已生效。" ;;
        pw_empty) echo "空密码，未修改。" ;;
        pw_new_ssh_prompt) echo "输入新的 SSH 密码（ESC 取消）: " ;;
        pw_cancelled) echo "已取消。" ;;
        shell_title) echo "本地命令行" ;;
        shell_text) echo "当前是 root shell。输入 exit 回到主菜单。" ;;
        shell_exit) echo "已退出命令行，返回主菜单。" ;;
        menu_confirm_reboot) echo "确定重启？" ;;
        menu_confirm_shutdown) echo "确定关机？" ;;
        pw_title)        echo "4. 密码文件" ;;
        *)               echo "$key" ;;
    esac
}

set_language() {
    local lang="$1"
    AI_BOOT_LANG="$lang"
    mkdir -p "$(dirname "$LANG_FILE")" 2>/dev/null || true
    printf '%s\n' "$lang" > "$LANG_FILE" 2>/dev/null || true
    cfg_set lang "$lang" >/dev/null 2>&1 || true
}

# ============================================================
# 六点五、控制台字体（中文能不能显示的前提）
# ============================================================
# 4.1 的中文全部显示成缺字方块，原因不在脚本，而在控制台字体：
#   /etc/default/console-setup 里是 FONTFACE="Fixed" FONTSIZE="8x16"，
#   选中的是 Lat15-Fixed16，一个 CJK 字形都没有；ISO 里虽然装了
#   fonts-unifont，却从来没有人 setfont 过任何含 CJK 的控制台字体。
#
# 另一个硬约束（在真机里实测过）：内核的帧缓冲控制台**只接受 256 或
# 512 个字形**的字体，其它数量一律 ioctl(KDFONTOP) 返回 EINVAL
# （257/513 全部失败）。所以别想着塞一份完整 CJK 字体进来 ——
# unifont.hex 有 5.7 万个字形，这条路走不通。
#
# 构建时用 tools/mkcjkfont.py 生成一份 512 字形的子集字体：
#   字形 0..127   = U+0000..U+007F（ASCII，保持传统 charmap 正常）
#   字形 128..511 = 界面里真正会用到的汉字/标点（最多 384 个）
# 字体放 /usr/local/share/ai-boot/aiboot-cjk.psf.gz；
# tests/check_cjk_font.sh 会断言"界面上要显示的字符一个都不缺"。
# 两套字体，按语言自动选：
#   en（默认）= 底子自带的 Lat15-Fixed16，8x16 —— 就是 4.0 那种紧凑样子，
#                80 列变 160 列，框线短、字小、一屏放得下
#   zh        = 本项目生成的 512 字形 CJK 字体，16x16 —— 汉字可读，
#                但每格大一倍，所以只在选了中文时才用
# 这样"紧凑"和"中文"不再互相打架：默认真·4.0 外观，要中文再换。
AI_BOOT_FONT_CJK="/usr/local/share/ai-boot/aiboot-cjk.psf.gz"
AI_BOOT_FONT_LATIN="/usr/share/consolefonts/Lat15-Fixed16.psf.gz"
AI_BOOT_FONT_APPLIED=""

# 重新从配置/语言文件读一次语言。
# 4.1/4.2 的 bug：切语言的 set_language 跑在**子进程**里，主菜单进程的
# AI_BOOT_LANG 是启动时读一次的，改完没人重读 —— 于是"选了中文主菜单
# 还是英文"，必须重启才生效。
# ------------------------------------------------------------
# sshd drop-in（公共库，ai-ssh.sh 与急救路径共用）
# 4.1 的坑：这个函数只写在 ai-ssh.sh 里，而急救路径 ai-rescue.sh 只 source 了
# network/password —— 于是急救起 sshd 时**根本没写 drop-in**，配置里的
# ai_user / ssh_port / ssh_allow_root 全不生效，屏幕给了密码却连不上。
# ------------------------------------------------------------
SSHD_DROPIN="/etc/ssh/sshd_config.d/aiboot.conf"

apply_sshd_config() {
    local port rootok user ok=1
    port="$(cfg_get ssh_port)"; [ -n "$port" ] || port=22
    case "$port" in
        ''|*[!0-9]*) port=22 ;;
        *) if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then port=22; fi ;;
    esac
    rootok="$(cfg_get ssh_allow_root)"
    user="$(ai_user_name)"

    mkdir -p "$(dirname "$SSHD_DROPIN")" 2>/dev/null || ok=0
    if [ "$ok" = "1" ]; then
        {
            printf '# generated by AI-Boot %s from %s\n' "$AI_BOOT_VERSION" "$CONFIG_FILE"
            printf 'Port %s\n' "$port"
            printf 'PasswordAuthentication yes\n'
            if [ "$rootok" = "1" ]; then
                # AllowUsers 是白名单：只写 PermitRootLogin yes 而 root 不在
                # 白名单里，root 照样登不进来 —— 必须一起放进去。
                printf 'PermitRootLogin yes\n'
                printf 'AllowUsers %s root\n' "$user"
            else
                printf 'PermitRootLogin no\n'
                printf 'AllowUsers %s\n' "$user"
            fi
        } > "$SSHD_DROPIN" 2>/dev/null || ok=0
    fi
    [ "$ok" = "1" ] || { echo "WARNING: cannot write $SSHD_DROPIN"; return 1; }

    # 配置写坏会把一个本来能用的 sshd 弄挂，远程就再也回不来了 —— 先验语法，
    # 不通过就把 drop-in 删掉，退回发行版默认配置。
    if command -v sshd >/dev/null 2>&1; then
        if ! sshd -t 2>/dev/null; then
            echo "WARNING: sshd config test failed; falling back to the default config."
            rm -f "$SSHD_DROPIN" 2>/dev/null || true
            return 1
        fi
    fi
    return 0
}

reload_language() {
    # 必须以**磁盘上真实的文件**为准。
    # 上一版先看 ${CFG_FROM_FILE[lang]}，那是本进程 **启动时** 载入配置的快照；
    # 语言是子进程（ai-config.sh）改的，父进程的内存副本永远不变 —— 于是
    # "按 L 切中文，主菜单还是英文"，必须重启才生效。已用真库复现。
    local v=""
    if [ -f "$LANG_FILE" ]; then
        v="$(tr -d '\n\r' < "$LANG_FILE" 2>/dev/null || true)"
    fi
    if [ -z "$v" ] && [ -f "$CONFIG_FILE" ]; then
        v="$(sed -n 's/^[[:space:]]*lang[[:space:]]*=[[:space:]]*//p' "$CONFIG_FILE" 2>/dev/null | tail -n 1 | tr -d '\r')"
    fi
    if [ -z "$v" ]; then
        v="${CFG[lang]:-en}"
    fi
    case "$v" in
        zh|en) AI_BOOT_LANG="$v" ;;
        *)     AI_BOOT_LANG="en" ;;
    esac
    export AI_BOOT_LANG
    # 语言决定字体（8px/16px 格），字体决定界面列数 —— 必须跟着重算，
    # 否则切中文后还按 72 列排版，整框会被拉长一倍。
    command -v ui_init_layout >/dev/null 2>&1 && ui_init_layout
    return 0
}

# 把字体装到当前控制台。$1=1 表示强制重装（切语言后要立刻换字体）。
console_font_init() {
    local force="${1:-0}" tty="" f=""

    # 中文装不上就回滚英文（要求第 7 条）：没有字体文件时**绝不能**还用中文，
    # 那会整屏方块，比英文更糟。
    if [ "$AI_BOOT_LANG" = "zh" ] && [ ! -r "$AI_BOOT_FONT_CJK" ]; then
        echo "WARNING: CJK console font missing; UI rolled back to English."
        AI_BOOT_LANG="en"
        export AI_BOOT_LANG
        command -v set_language >/dev/null 2>&1 && set_language en >/dev/null 2>&1
    fi

    if [ "$AI_BOOT_LANG" = "zh" ]; then
        f="$AI_BOOT_FONT_CJK"
    else
        f="$AI_BOOT_FONT_LATIN"
    fi
    [ -r "$f" ] || f="$AI_BOOT_FONT_LATIN"
    [ -r "$f" ] || return 0
    if [ "$force" != "1" ] && [ "$AI_BOOT_FONT_APPLIED" = "$f" ]; then
        return 0
    fi
    command -v setfont >/dev/null 2>&1 || return 0
    tty="$(tty 2>/dev/null || true)"
    case "$tty" in
        /dev/tty[0-9]*) ;;
        *) return 0 ;;
    esac
    [ -c "$tty" ] || return 0

    if ! setfont -C "$tty" "$f" 2>/dev/null; then
        if [ "$f" = "$AI_BOOT_FONT_CJK" ] && [ -r "$AI_BOOT_FONT_LATIN" ]; then
            echo "WARNING: CJK console font failed to load; UI rolled back to English."
            AI_BOOT_LANG="en"
            export AI_BOOT_LANG
            command -v set_language >/dev/null 2>&1 && set_language en >/dev/null 2>&1
            setfont -C "$tty" "$AI_BOOT_FONT_LATIN" 2>/dev/null || true
            AI_BOOT_FONT_APPLIED="$AI_BOOT_FONT_LATIN"
            export AI_BOOT_FONT_APPLIED
        fi
        return 1
    fi
    AI_BOOT_FONT_APPLIED="$f"
    export AI_BOOT_FONT_APPLIED
    return 0
}

# ============================================================
# 初始化
# ============================================================
init_paths
LOCK_FILE="$AI_BOOT_DIR/ai-boot.lock"
export LOCK_FILE
cfg_load
key_pb_init

# 语言优先级：配置文件里真的写了 lang > 上次选择（lang 文件）> en
# 注意判断的是 CFG_FROM_FILE，不是 cfg_get：cfg_get 在没写时也返回默认值 en，
# 用它会把这个条件变成恒真，lang 文件就永远读不到了。
if [ -n "${CFG_FROM_FILE[lang]:-}" ]; then
    AI_BOOT_LANG="$(cfg_get lang)"
elif [ -f "$LANG_FILE" ]; then
    AI_BOOT_LANG="$(tr -d '\n\r' < "$LANG_FILE" 2>/dev/null || echo en)"
fi
[ -n "$AI_BOOT_LANG" ] || AI_BOOT_LANG="en"
export AI_BOOT_LANG

# ★ 字体必须在语言确定**之后**才装（关键顺序）★
# 原来 console_font_init 写在语言赋值之前。每个子界面（ai-ssh / ai-monitor /
# ai-config / ai-tools / ai-rescue）都是**新进程**、会重新 source 本文件，
# 那一刻 AI_BOOT_LANG 还是默认的 "en"，于是它把父菜单已经装好的 CJK 字体
# **换回拉丁字体** —— 现象就是"主菜单是中文、一进子界面全变方块"。
# 实测：SSH/监视页整屏 ♦，只有密码那行 ASCII 正常。
reload_language
console_font_init

# 只读 / 内存两种情况下必须让用户知道，否则“改了没生效”会变成玄学。
# AI_BOOT_WARNED 会 export 出去：AI 急救模式一路会再拉起 ai-monitor.sh /
# ai-shell.sh 等独立进程，每个进程都会重新 source 本文件，
# 不去重的话同一句警告在整个流程里会重复印好几遍（已实测 3 遍）。
if [ -z "${AI_BOOT_WARNED:-}" ]; then
    if [ "$CFG_WRITABLE" != "1" ]; then
        echo "$(t warn_readonly)"
        echo "$(t warn_where)$CONFIG_FILE"
        export AI_BOOT_WARNED=1
    elif [ "$CFG_VOLATILE" = "1" ]; then
        echo "$(t warn_volatile)"
        echo "$(t warn_where)$CONFIG_FILE"
        export AI_BOOT_WARNED=1
    fi
fi
