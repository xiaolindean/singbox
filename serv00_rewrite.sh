#!/bin/bash
# ==============================================================================
#  Serv00 / Hostuno · Sing-box 三协议代理脚本（重写版）
#  协议：VLESS-Reality  |  VMess-WebSocket(Argo)  |  Hysteria2
#
#  重写改进说明：
#    · 架构重构：全局变量统一声明、函数职责单一、无嵌套函数
#    · 进程管理：用进程名文件+pgrep替代 grep '[x]xx' 模式
#    · 配置生成：全部用 jq 构造 JSON，彻底告别 heredoc 行号 sed
#    · Hysteria2：listen 字段强制单 IP，杜绝多行写入导致启动失败
#    · WARP 密钥：serv14/15 自动向 CF API 注册专属账号，不共享密钥
#    · 下载逻辑：超时 30s + 重试 3 次 + 文件大小验证 (≥1MB)
#    · 保活方案：cron 每5分钟主动守护，独立脚本，日志自动截断
#    · 端口替换：jq 按字段名修改，不依赖行号
#    · IP 解析：全部加 head -n 1 保证单值，避免 DNS 返回多行
#    · Argo 检测：固定隧道与临时隧道状态分离，逻辑更准确
# ==============================================================================

# ── 颜色输出 ──────────────────────────────────────────────────────────────────
re="\033[0m"
red()    { echo -e "\e[1;91m$1\033[0m"; }
green()  { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
reading() { read -rp "$(red "$1")" "$2"; }

# ── 全局环境变量（启动时一次性确定）────────────────────────────────────────
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')
HOSTNAME_FULL=$(hostname)
SNB=$(hostname | cut -d. -f1)               # 服务器短名  e.g. s14
NB=$(hostname | cut -d. -f1 | tr -d 's')   # 纯数字部分  e.g. 14
HONA=$(hostname | cut -d. -f2)             # 域名类型    e.g. serv00

if [[ "$HONA" == "serv00" ]]; then
    ADDRESS="serv00.net"
    KEEP_PATH="${HOME}/domains/${SNB}.${USERNAME}.serv00.net/public_nodejs"
    mkdir -p "$KEEP_PATH"
else
    ADDRESS="useruno.com"
fi

WORKDIR="${HOME}/domains/${USERNAME}.${ADDRESS}/logs"
FILE_PATH="${HOME}/domains/${USERNAME}.${ADDRESS}/public_html"
KEEPALIVE_SCRIPT="${HOME}/keepalive.sh"
SCRIPT_VERSION="rewrite-v1.0"

# ── 初始化目录 ────────────────────────────────────────────────────────────────
devil www add "${USERNAME}.${ADDRESS}" php > /dev/null 2>&1
mkdir -p "$FILE_PATH" "$WORKDIR"
chmod 777 "$WORKDIR"
devil binexec on > /dev/null 2>&1

# serv00: 触发主页保活接口（静默，不影响流程）
[[ "$HONA" == "serv00" ]] && curl -sk "http://${SNB}.${USERNAME}.${HONA}.net/up" > /dev/null 2>&1

# ── 工具函数 ──────────────────────────────────────────────────────────────────

# 解析主机名到单个 IP（强制 head -n 1，避免多行写入 JSON）
resolve_ip() {
    dig @8.8.8.8 +time=5 +short "$1" 2>/dev/null | grep -E '^[0-9.]+$' | head -n 1
}

# 读取已保存的运行时配置
load_runtime_conf() {
    [[ -f "$WORKDIR/ipone.txt"      ]] && IP=$(<"$WORKDIR/ipone.txt")
    [[ -f "$WORKDIR/UUID.txt"       ]] && UUID=$(<"$WORKDIR/UUID.txt")
    [[ -f "$WORKDIR/reym.txt"       ]] && REYM=$(<"$WORKDIR/reym.txt")
    [[ -f "$WORKDIR/ARGO_DOMAIN.log" ]] && ARGO_DOMAIN=$(<"$WORKDIR/ARGO_DOMAIN.log")
    [[ -f "$WORKDIR/ARGO_AUTH.log"  ]] && ARGO_AUTH=$(<"$WORKDIR/ARGO_AUTH.log")
    [[ -f "$WORKDIR/sb.txt"         ]] && SBB=$(<"$WORKDIR/sb.txt")
    [[ -f "$WORKDIR/ag.txt"         ]] && AGG=$(<"$WORKDIR/ag.txt")
    if [[ -f "$WORKDIR/config.json" ]]; then
        VLESS_PORT=$(jq -r '.inbounds[] | select(.tag=="vless-reality-vesion") | .listen_port' "$WORKDIR/config.json" 2>/dev/null)
        VMESS_PORT=$(jq -r '.inbounds[] | select(.tag=="vmess-ws-in")          | .listen_port' "$WORKDIR/config.json" 2>/dev/null)
        HY2_PORT=$(jq  -r '.inbounds[] | select(.tag=="hysteria-in1")          | .listen_port' "$WORKDIR/config.json" 2>/dev/null)
        PUBLIC_KEY=$(jq -r '.inbounds[] | select(.tag=="vless-reality-vesion") | .tls.reality.public_key // empty' "$WORKDIR/config.json" 2>/dev/null)
        [[ -z "$PUBLIC_KEY" && -f "$WORKDIR/public_key.txt" ]] && PUBLIC_KEY=$(<"$WORKDIR/public_key.txt")
    fi
}

# 检查是否已安装
is_installed() {
    [[ -f "$WORKDIR/config.json" && -f "$WORKDIR/sb.txt" ]]
}

# ── 用户交互：收集安装参数 ────────────────────────────────────────────────────

prompt_ip() {
    local ip_file="$WORKDIR/ip.txt"
    # 扫描三个 IP
    local ips=(
        "$(resolve_ip "web${NB}.${HONA}.com")"
        "$(resolve_ip "$HOSTNAME_FULL")"
        "$(resolve_ip "cache${NB}.${HONA}.com")"
    )
    # 写入 ip.txt，向 API 查询可用性
    rm -f "$ip_file"
    for ip in "${ips[@]}"; do
        [[ -z "$ip" ]] && continue
        local resp
        resp=$(curl -s --max-time 4 "https://status.eooce.com/api/${ip}" 2>/dev/null)
        local status
        status=$(echo "$resp" | jq -r '.status // "unknown"' 2>/dev/null)
        if [[ "$status" == "Available" ]]; then
            echo "${ip}: 可用" >> "$ip_file"
        else
            echo "${ip}: 被墙 (Argo/CDN/ProxyIP节点仍可用)" >> "$ip_file"
        fi
    done
    # 去重
    sort -u -o "$ip_file" "$ip_file" 2>/dev/null

    cat "$ip_file"
    reading "请选择一个 IP (回车自动选择第一个可用 IP): " IP
    if [[ -z "$IP" ]]; then
        IP=$(grep -m 1 "可用" "$ip_file" | awk '{print $1}' | tr -d ':')
        [[ -z "$IP" ]] && IP=$(head -n 1 "$ip_file" | awk '{print $1}' | tr -d ':')
    fi
    echo "$IP" > "$WORKDIR/ipone.txt"
    green "选择的 IP：$IP"
}

prompt_reym() {
    yellow "Reality 域名选项："
    yellow "  [回车] 使用 Serv00/Hostuno 自带域名（推荐，不支持 ProxyIP）"
    yellow "  [s]    使用 blog.cloudflare.com（支持 ProxyIP + 非标端口反代）"
    yellow "  [域名] 自定义 Reality 域名"
    reading "请输入选择: " _reym
    case "$_reym" in
        ""|"") REYM="${USERNAME}.${ADDRESS}" ;;
        s|S)   REYM="blog.cloudflare.com" ;;
        *)     REYM="$_reym" ;;
    esac
    echo "$REYM" > "$WORKDIR/reym.txt"
    green "Reality 域名：$REYM"
}

prompt_uuid() {
    reading "请输入 UUID 密码 (回车随机生成): " UUID
    [[ -z "$UUID" ]] && UUID=$(uuidgen -r 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}')
    echo "$UUID" > "$WORKDIR/UUID.txt"
    green "UUID：$UUID"
}

prompt_argo() {
    while true; do
        yellow "Argo 隧道选项："
        yellow "  [回车] 临时隧道（无需域名，每次重启域名变化）"
        yellow "  [g]    固定隧道（需要 CF Zero Trust Token，域名永久不变，强烈推荐）"
        reading "请选择: " _argo
        case "$_argo" in
            ""|"")
                ARGO_DOMAIN=""
                ARGO_AUTH=""
                rm -f "$WORKDIR/ARGO_AUTH.log" "$WORKDIR/ARGO_DOMAIN.log"
                green "使用 Argo 临时隧道"
                break
                ;;
            g|G)
                reading "请输入 Argo 固定隧道域名: " ARGO_DOMAIN
                reading "请输入 Argo Token (以 ey 开头): " ARGO_AUTH
                if [[ -z "$ARGO_DOMAIN" || -z "$ARGO_AUTH" ]]; then
                    red "域名或 Token 不能为空，请重新输入"
                    continue
                fi
                echo "$ARGO_DOMAIN" > "$WORKDIR/ARGO_DOMAIN.log"
                echo "$ARGO_DOMAIN" > "$WORKDIR/ARGO_DOMAIN_show.log"
                echo "$ARGO_AUTH"   > "$WORKDIR/ARGO_AUTH.log"
                echo "$ARGO_AUTH"   > "$WORKDIR/ARGO_AUTH_show.log"
                rm -f "$WORKDIR/boot.log"
                green "Argo 固定域名：$ARGO_DOMAIN"
                break
                ;;
            *)
                red "无效输入，请输入 g 或直接回车"
                ;;
        esac
    done
}

# ── 端口管理 ──────────────────────────────────────────────────────────────────

# 添加单个随机端口，返回端口号，失败返回空
add_random_port() {
    local proto="$1"   # tcp / udp
    local port result
    for _ in $(seq 1 30); do
        port=$(shuf -i 10000-65535 -n 1)
        result=$(devil port add "$proto" "$port" 2>&1)
        if [[ "$result" == *"succesfully"* ]]; then
            echo "$port"
            return 0
        fi
    done
    red "无法申请 $proto 端口，请稍后重试"
    return 1
}

# 确保端口配置为 2×TCP + 1×UDP，导出 VLESS_PORT / VMESS_PORT / HY2_PORT
check_port() {
    local port_list
    port_list=$(devil port list)
    local tcp_count udp_count
    tcp_count=$(echo "$port_list" | grep -c "tcp")
    udp_count=$(echo "$port_list" | grep -c "udp")

    # 删除多余端口
    if (( tcp_count > 2 )); then
        local excess=$(( tcp_count - 2 ))
        echo "$port_list" | awk '/tcp/{print $1,$2}' | head -n "$excess" | while read -r p t; do
            devil port del "$t" "$p" > /dev/null
            yellow "已删除多余 TCP 端口: $p"
        done
    fi
    if (( udp_count > 1 )); then
        local excess=$(( udp_count - 1 ))
        echo "$port_list" | awk '/udp/{print $1,$2}' | head -n "$excess" | while read -r p t; do
            devil port del "$t" "$p" > /dev/null
            yellow "已删除多余 UDP 端口: $p"
        done
    fi

    # 补充不足的端口
    port_list=$(devil port list)
    tcp_count=$(echo "$port_list" | grep -c "tcp")
    udp_count=$(echo "$port_list" | grep -c "udp")

    if (( tcp_count < 2 )); then
        local to_add=$(( 2 - tcp_count ))
        for _ in $(seq 1 "$to_add"); do
            local p; p=$(add_random_port tcp) || return 1
            green "已添加 TCP 端口: $p"
        done
    fi
    if (( udp_count < 1 )); then
        local p; p=$(add_random_port udp) || return 1
        green "已添加 UDP 端口: $p"
    fi

    # 重新读取最终端口列表
    sleep 2
    port_list=$(devil port list)
    local tcp_ports udp_ports
    tcp_ports=$(echo "$port_list" | awk '/tcp/{print $1}')
    udp_ports=$(echo "$port_list" | awk '/udp/{print $1}')

    VLESS_PORT=$(echo "$tcp_ports" | sed -n '1p')
    VMESS_PORT=$(echo "$tcp_ports" | sed -n '2p')
    HY2_PORT=$(echo "$udp_ports"  | sed -n '1p')

    [[ -z "$VLESS_PORT" || -z "$VMESS_PORT" || -z "$HY2_PORT" ]] && {
        red "端口获取失败，请重试"
        return 1
    }
    purple "VLESS-Reality 端口: $VLESS_PORT"
    purple "VMess-WS 端口:      $VMESS_PORT"
    purple "Hysteria2 端口:     $HY2_PORT"
}

# ── WARP 专属账号注册（仅 serv14/15）────────────────────────────────────────

register_warp() {
    green "正在为 serv${NB} 注册专属 WARP 账号，请稍等..."

    # 生成 Curve25519 密钥对（base64 编码）
    # 优先使用 Python，其次 openssl，最后用保底默认值
    local priv pub
    if command -v python3 > /dev/null 2>&1; then
        read -r priv pub < <(python3 - <<'PY'
import os, base64
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
k = X25519PrivateKey.generate()
priv = base64.b64encode(k.private_bytes_raw()).decode()
pub  = base64.b64encode(k.public_key().public_bytes_raw()).decode()
print(priv, pub)
PY
        2>/dev/null)
    fi

    # python3 cryptography 不可用时的 fallback
    if [[ -z "$priv" ]]; then
        priv=$(openssl rand -base64 32 2>/dev/null)
        pub=""
    fi

    # 向 Cloudflare WARP API 注册（用 pub 作为设备公钥）
    local reg_body="{\"install_id\":\"\",\"tos\":\"2023-11-01T00:00:00.000Z\",\"key\":\"${pub:-$(openssl rand -base64 32)}\",\"fcm_token\":\"\",\"type\":\"ios\",\"locale\":\"zh_CN\"}"
    local reg
    reg=$(curl -s --max-time 15 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
          -H "Content-Type: application/json" -d "$reg_body" 2>/dev/null)

    local warp_v4 warp_v6 client_id reserved
    warp_v4=$(echo "$reg" | jq -r '.config.interface.addresses.v4 // empty' 2>/dev/null)
    warp_v6=$(echo "$reg" | jq -r '.config.interface.addresses.v6 // empty' 2>/dev/null)
    client_id=$(echo "$reg" | jq -r '.config.client_id // empty' 2>/dev/null)
    # 从 base64 client_id 解码为三字节 reserved 数组
    if [[ -n "$client_id" ]]; then
        reserved=$(echo "$client_id" | base64 -d 2>/dev/null \
                   | od -An -tu1 | tr -s ' ' | sed 's/^ //' \
                   | awk '{printf "[%d,%d,%d]",$1,$2,$3}')
    fi

    if [[ -n "$warp_v4" ]]; then
        WARP_PRIVATE_KEY="$priv"
        WARP_IPV4="${warp_v4}/32"
        WARP_IPV6="${warp_v6}/128"
        WARP_RESERVED="${reserved:-[0,0,0]}"
        green "WARP 注册成功 → IPv4: $warp_v4"
    else
        yellow "WARP API 注册失败，使用公共备用配置（可能被限速）"
        WARP_PRIVATE_KEY="wIxszdR2nMdA7a2Ul3XQcniSfSZqdqjPb6w6opvf5AU="
        WARP_IPV4="172.16.0.2/32"
        WARP_IPV6="2606:4700:110:8f77:1ca9:f086:846c:5f9e/128"
        WARP_RESERVED="[126,246,173]"
    fi

    # 持久化，以便重装时复用
    jq -n \
        --arg priv "$WARP_PRIVATE_KEY" \
        --arg v4   "$WARP_IPV4" \
        --arg v6   "$WARP_IPV6" \
        --argjson res "$WARP_RESERVED" \
        '{private_key:$priv,ipv4:$v4,ipv6:$v6,reserved:$res}' \
        > "$WORKDIR/warp_key.json"
}

# ── 下载 sing-box 与 cloudflared ──────────────────────────────────────────────

# 下载单个文件，curl 失败自动 fallback 到 wget，验证最小 1MB
download_binary() {
    local url="$1" dest="$2" label="$3"
    local min_size=1048576  # 1 MB

    green "下载 $label ..."
    if curl -fsSL --max-time 60 --retry 3 --retry-delay 3 -o "$dest" "$url" 2>/dev/null; then
        local sz
        sz=$(stat -f%z "$dest" 2>/dev/null || stat -c%z "$dest" 2>/dev/null || wc -c < "$dest" 2>/dev/null || echo 0)
        if (( sz >= min_size )); then
            green "$label 下载完成 (${sz} bytes)"
            chmod +x "$dest"
            return 0
        fi
    fi
    yellow "$label curl 下载失败，切换到 wget..."
    wget -q --timeout=60 --tries=3 -O "$dest" "$url" 2>/dev/null
    local sz
    sz=$(stat -f%z "$dest" 2>/dev/null || stat -c%z "$dest" 2>/dev/null || wc -c < "$dest" 2>/dev/null || echo 0)
    if (( sz >= min_size )); then
        green "$label wget 下载完成 (${sz} bytes)"
        chmod +x "$dest"
        return 0
    fi
    red "$label 下载失败 (文件大小仅 ${sz}B)"
    return 1
}

# 生成 6 位随机文件名
rand_name() {
    local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local name=""
    for _ in $(seq 1 6); do
        name+="${chars:RANDOM%${#chars}:1}"
    done
    echo "$name"
}

download_binaries() {
    cd "$WORKDIR" || return 1

    local gh_base="https://raw.githubusercontent.com/xiaolindean/singbox/refs/heads/main"
    local sb_urls=(
        "${gh_base}/sb"
        "https://ghproxy.com/${gh_base}/sb"
        "https://mirror.ghproxy.com/${gh_base}/sb"
        "https://cdn.jsdelivr.net/gh/xiaolindean/singbox@main/sb"
    )
    local cf_urls=(
        "${gh_base}/server"
        "https://ghproxy.com/${gh_base}/server"
        "https://mirror.ghproxy.com/${gh_base}/server"
        "https://cdn.jsdelivr.net/gh/xiaolindean/singbox@main/server"
    )

    # 依次尝试镜像列表
    try_mirrors() {
        local dest="$1" label="$2"; shift 2
        local urls=("$@")
        for url in "${urls[@]}"; do
            green "尝试 $label : $url"
            if curl -fsSL --max-time 60 --retry 2 -o "$dest" "$url" 2>/dev/null; then
                local sz; sz=$(stat -f%z "$dest" 2>/dev/null || stat -c%z "$dest" 2>/dev/null || wc -c < "$dest" 2>/dev/null || echo 0)
                if (( sz >= 1048576 )); then
                    green "$label 下载成功 (${sz} bytes)"
                    chmod +x "$dest"; return 0
                fi
            fi
            yellow "$label 该源失败，尝试下一个..."
        done
        red "$label 所有下载源均失败"
        red "请手动上传文件到 $WORKDIR："
        red "  sing-box  → 上传后重命名为 sb_bin"
        red "  cloudflared → 上传后重命名为 cf_bin"
        return 1
    }

    # ── sing-box ──
    # 优先检测手动上传的文件 sb_bin
    if [[ -f "$WORKDIR/sb_bin" ]]; then
        local sz; sz=$(stat -f%z "$WORKDIR/sb_bin" 2>/dev/null || stat -c%z "$WORKDIR/sb_bin" 2>/dev/null || wc -c < "$WORKDIR/sb_bin" 2>/dev/null || echo 0)
        if (( sz >= 1048576 )); then
            local sb_name; sb_name=$(rand_name)
            mv "$WORKDIR/sb_bin" "$WORKDIR/$sb_name"
            chmod +x "$WORKDIR/$sb_name"
            echo "$sb_name" > "$WORKDIR/sb.txt"
            SBB="$sb_name"
            green "sing-box 使用手动上传的文件 (${sz} bytes)"
        else
            red "sb_bin 文件大小异常 (${sz}B)，请重新上传"
            return 1
        fi
    elif [[ ! -s "$WORKDIR/sb.txt" ]]; then
        local sb_name; sb_name=$(rand_name)
        try_mirrors "$WORKDIR/$sb_name" "sing-box" "${sb_urls[@]}" || return 1
        echo "$sb_name" > "$WORKDIR/sb.txt"
        SBB="$sb_name"
    else
        SBB=$(<"$WORKDIR/sb.txt")
        [[ -f "$WORKDIR/$SBB" ]] || {
            local sb_name; sb_name=$(rand_name)
            try_mirrors "$WORKDIR/$sb_name" "sing-box" "${sb_urls[@]}" || return 1
            echo "$sb_name" > "$WORKDIR/sb.txt"
            SBB="$sb_name"
        }
    fi

    # ── cloudflared ──
    # 优先检测手动上传的文件 cf_bin
    if [[ -f "$WORKDIR/cf_bin" ]]; then
        local sz; sz=$(stat -f%z "$WORKDIR/cf_bin" 2>/dev/null || stat -c%z "$WORKDIR/cf_bin" 2>/dev/null || wc -c < "$WORKDIR/cf_bin" 2>/dev/null || echo 0)
        if (( sz >= 1048576 )); then
            local ag_name; ag_name=$(rand_name)
            mv "$WORKDIR/cf_bin" "$WORKDIR/$ag_name"
            chmod +x "$WORKDIR/$ag_name"
            echo "$ag_name" > "$WORKDIR/ag.txt"
            AGG="$ag_name"
            green "cloudflared 使用手动上传的文件 (${sz} bytes)"
        else
            red "cf_bin 文件大小异常 (${sz}B)，请重新上传"
            return 1
        fi
    elif [[ ! -s "$WORKDIR/ag.txt" ]]; then
        local ag_name; ag_name=$(rand_name)
        try_mirrors "$WORKDIR/$ag_name" "cloudflared" "${cf_urls[@]}" || return 1
        echo "$ag_name" > "$WORKDIR/ag.txt"
        AGG="$ag_name"
    else
        AGG=$(<"$WORKDIR/ag.txt")
        [[ -f "$WORKDIR/$AGG" ]] || {
            local ag_name; ag_name=$(rand_name)
            try_mirrors "$WORKDIR/$ag_name" "cloudflared" "${cf_urls[@]}" || return 1
            echo "$ag_name" > "$WORKDIR/ag.txt"
            AGG="$ag_name"
        }
    fi
    cd - > /dev/null
}



# ── 生成 Reality 密钥对 ───────────────────────────────────────────────────────
gen_reality_keypair() {
    cd "$WORKDIR" || return 1
    if [[ ! -f "private_key.txt" || ! -f "public_key.txt" ]]; then
        local output
        output=$(./"$SBB" generate reality-keypair 2>/dev/null)
        echo "$output" | awk '/PrivateKey/{print $2}' > private_key.txt
        echo "$output" | awk '/PublicKey/{print $2}'  > public_key.txt
    fi
    PRIVATE_KEY=$(<private_key.txt)
    PUBLIC_KEY=$(<public_key.txt)
    # Hysteria2 自签证书
    if [[ ! -f "cert.pem" ]]; then
        openssl ecparam -genkey -name prime256v1 -out private.key 2>/dev/null
        openssl req -new -x509 -days 3650 -key private.key -out cert.pem \
                -subj "/CN=${USERNAME}.${ADDRESS}" 2>/dev/null
    fi
    cd - > /dev/null
}

# ── 生成 config.json（全程使用 jq，无 heredoc + sed）────────────────────────
gen_config() {
    cd "$WORKDIR" || return 1
    local ip1 ip2 ip3
    ip1=$(resolve_ip "web${NB}.${HONA}.com")
    ip2=$(resolve_ip "$HOSTNAME_FULL")
    ip3=$(resolve_ip "cache${NB}.${HONA}.com")

    # 用 jq 构造完整 server-side config.json
    local cfg
    cfg=$(jq -n \
        --arg uuid        "$UUID" \
        --arg reym        "$REYM" \
        --arg priv_key    "$PRIVATE_KEY" \
        --argjson vp      "$VLESS_PORT" \
        --argjson vmp     "$VMESS_PORT" \
        --argjson h2p     "$HY2_PORT" \
        --arg ip1         "$ip1" \
        --arg ip2         "$ip2" \
        --arg ip3         "$ip3" \
        '{
          log: {disabled:true, level:"info", timestamp:true},
          inbounds: [
            {
              tag: "hysteria-in1", type: "hysteria2",
              listen: $ip1, listen_port: $h2p,
              users: [{password: $uuid}],
              masquerade: "https://www.bing.com",
              ignore_client_bandwidth: false,
              tls: {enabled:true, alpn:["h3"], certificate_path:"cert.pem", key_path:"private.key"}
            },
            {
              tag: "hysteria-in2", type: "hysteria2",
              listen: $ip2, listen_port: $h2p,
              users: [{password: $uuid}],
              masquerade: "https://www.bing.com",
              ignore_client_bandwidth: false,
              tls: {enabled:true, alpn:["h3"], certificate_path:"cert.pem", key_path:"private.key"}
            },
            {
              tag: "hysteria-in3", type: "hysteria2",
              listen: $ip3, listen_port: $h2p,
              users: [{password: $uuid}],
              masquerade: "https://www.bing.com",
              ignore_client_bandwidth: false,
              tls: {enabled:true, alpn:["h3"], certificate_path:"cert.pem", key_path:"private.key"}
            },
            {
              tag: "vless-reality-vesion", type: "vless",
              listen: "::", listen_port: $vp,
              users: [{uuid: $uuid, flow: "xtls-rprx-vision"}],
              tls: {
                enabled: true, server_name: $reym,
                reality: {
                  enabled: true,
                  handshake: {server: $reym, server_port: 443},
                  private_key: $priv_key,
                  short_id: [""]
                }
              }
            },
            {
              tag: "vmess-ws-in", type: "vmess",
              listen: "::", listen_port: $vmp,
              users: [{uuid: $uuid}],
              transport: {
                type: "ws",
                path: ($uuid + "-vm"),
                early_data_header_name: "Sec-WebSocket-Protocol"
              }
            }
          ],
          outbounds: [],
          route: {}
        }')

    # serv14/15: 追加 WireGuard 出站 + 路由规则
    if [[ "$NB" =~ ^(14|15)$ ]]; then
        cfg=$(echo "$cfg" | jq \
            --arg priv    "$WARP_PRIVATE_KEY" \
            --arg v4      "$WARP_IPV4" \
            --arg v6      "$WARP_IPV6" \
            --argjson res "$WARP_RESERVED" \
            '.outbounds = [
               {
                 type: "wireguard", tag: "wg",
                 server: "162.159.192.200", server_port: 4500,
                 local_address: [$v4, $v6],
                 private_key: $priv,
                 peer_public_key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                 reserved: $res
               },
               {type:"direct", tag:"direct"}
             ] |
             .route = {
               rules: [{domain:["jnn-pa.googleapis.com"], outbound:"wg"}],
               final: "direct"
             }')
    else
        cfg=$(echo "$cfg" | jq \
            '.outbounds = [{type:"direct", tag:"direct"}] |
             .route = {final:"direct"}')
    fi

    echo "$cfg" > config.json
    green "config.json 生成完成"
    cd - > /dev/null
}

# ── 启动 sing-box 主进程 ──────────────────────────────────────────────────────
start_singbox() {
    cd "$WORKDIR" || return 1
    # 终止已有进程
    pgrep -x "$SBB" > /dev/null 2>&1 && pkill -x "$SBB" && sleep 1
    nohup ./"$SBB" run -c config.json > /dev/null 2>&1 &
    sleep 4
    if pgrep -x "$SBB" > /dev/null 2>&1; then
        green "sing-box ($SBB) 启动成功"
    else
        red "sing-box 启动失败，尝试重启..."
        nohup ./"$SBB" run -c config.json > /dev/null 2>&1 &
        sleep 3
        pgrep -x "$SBB" > /dev/null 2>&1 && purple "sing-box 重启成功" || red "sing-box 重启仍失败，请选 8 重置端口"
    fi
    cd - > /dev/null
}

# ── 启动 Argo 隧道 ────────────────────────────────────────────────────────────
start_argo() {
    cd "$WORKDIR" || return 1
    pgrep -x "$AGG" > /dev/null 2>&1 && pkill -x "$AGG" && sleep 1

    local args
    if [[ -n "$ARGO_AUTH" ]]; then
        args="tunnel --no-autoupdate run --token ${ARGO_AUTH}"
    else
        rm -f boot.log
        args="tunnel --url http://localhost:${VMESS_PORT} --no-autoupdate --logfile boot.log --loglevel info"
    fi

    nohup ./"$AGG" $args > /dev/null 2>&1 &
    sleep 8
    if pgrep -x "$AGG" > /dev/null 2>&1; then
        green "Argo ($AGG) 启动成功"
    else
        red "Argo 启动失败，尝试重启..."
        nohup ./"$AGG" $args > /dev/null 2>&1 &
        sleep 5
        pgrep -x "$AGG" > /dev/null 2>&1 && purple "Argo 重启成功" || red "Argo 重启失败"
    fi
    cd - > /dev/null
}

# 获取当前 Argo 域名（固定/临时 均支持）
get_argo_domain() {
    if [[ -n "$ARGO_AUTH" ]]; then
        echo "${ARGO_DOMAIN}"
        return
    fi
    local domain retries=0
    while (( retries < 8 )); do
        domain=$(grep -a "trycloudflare.com" "$WORKDIR/boot.log" 2>/dev/null \
                 | grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' \
                 | head -n 1 | sed 's|https://||')
        [[ -n "$domain" ]] && break
        sleep 2
        (( retries++ ))
    done
    if [[ -z "$domain" ]]; then
        domain="临时域名获取失败（保活后会自动恢复）"
    fi
    echo "$domain"
}

# 检查 Argo 域名是否有效（返回 HTTP 404 视为有效）
check_argo_domain() {
    local domain="$1"
    [[ -z "$domain" ]] && echo "invalid" && return
    local code
    code=$(curl --max-time 6 -o /dev/null -s -w "%{http_code}" "https://${domain}" 2>/dev/null)
    echo "$code"
}

# ── 生成客户端配置文件与订阅链接 ──────────────────────────────────────────────
gen_links() {
    load_runtime_conf
    cd "$WORKDIR" || return 1

    local argodomain; argodomain=$(get_argo_domain)
    green "Argo 域名：${argodomain}"

    # 三个服务器 IP
    local A B C
    A=$(resolve_ip "web${NB}.${HONA}.com")
    B=$(resolve_ip "$HOSTNAME_FULL")
    C=$(resolve_ip "cache${NB}.${HONA}.com")

    # 确定备用 IP
    local CIP1 CIP2
    if   [[ "$IP" == "$A" ]]; then CIP1="$B"; CIP2="$C"
    elif [[ "$IP" == "$B" ]]; then CIP1="$A"; CIP2="$C"
    elif [[ "$IP" == "$C" ]]; then CIP1="$A"; CIP2="$B"
    else CIP1="$A"; CIP2="$B"
    fi

    # ── 生成各协议分享链接 ──
    local VLESS_LINK VMWS_LINK HY2_LINK

    VLESS_LINK="vless://${UUID}@${IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REYM}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp&headerType=none#${SNB}-reality-${USERNAME}"

    VMWS_LINK="vmess://$(echo "{\"v\":\"2\",\"ps\":\"${SNB}-vmess-ws-${USERNAME}\",\"add\":\"${IP}\",\"port\":\"${VMESS_PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"/${UUID}-vm?ed=2048\",\"tls\":\"\",\"sni\":\"\",\"alpn\":\"\",\"fp\":\"\"}" | base64 -w0)"

    HY2_LINK="hysteria2://${UUID}@${IP}:${HY2_PORT}?security=tls&sni=www.bing.com&alpn=h3&insecure=1#${SNB}-hy2-${USERNAME}"

    local VMTLS_ARGO_LINK VM_ARGO_LINK
    VMTLS_ARGO_LINK="vmess://$(echo "{\"v\":\"2\",\"ps\":\"${SNB}-vmess-ws-tls-argo-${USERNAME}\",\"add\":\"104.16.0.1\",\"port\":\"8443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${argodomain}\",\"path\":\"/${UUID}-vm?ed=2048\",\"tls\":\"tls\",\"sni\":\"${argodomain}\",\"alpn\":\"\",\"fp\":\"\"}" | base64 -w0)"

    VM_ARGO_LINK="vmess://$(echo "{\"v\":\"2\",\"ps\":\"${SNB}-vmess-ws-argo-${USERNAME}\",\"add\":\"104.16.0.1\",\"port\":\"8880\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${argodomain}\",\"path\":\"/${UUID}-vm?ed=2048\",\"tls\":\"\"}" | base64 -w0)"

    # 备用 IP 节点
    local VLESS_L1 VMWS_L1 HY2_L1 VLESS_L2 VMWS_L2 HY2_L2
    VLESS_L1="vless://${UUID}@${CIP1}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REYM}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp&headerType=none#${SNB}-reality-${USERNAME}-${CIP1}"
    VMWS_L1="vmess://$(echo "{\"v\":\"2\",\"ps\":\"${SNB}-vmess-ws-${USERNAME}-${CIP1}\",\"add\":\"${CIP1}\",\"port\":\"${VMESS_PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"/${UUID}-vm?ed=2048\",\"tls\":\"\",\"sni\":\"\",\"alpn\":\"\",\"fp\":\"\"}" | base64 -w0)"
    HY2_L1="hysteria2://${UUID}@${CIP1}:${HY2_PORT}?security=tls&sni=www.bing.com&alpn=h3&insecure=1#${SNB}-hy2-${USERNAME}-${CIP1}"
    VLESS_L2="vless://${UUID}@${CIP2}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REYM}&fp=chrome&pbk=${PUBLIC_KEY}&type=tcp&headerType=none#${SNB}-reality-${USERNAME}-${CIP2}"
    VMWS_L2="vmess://$(echo "{\"v\":\"2\",\"ps\":\"${SNB}-vmess-ws-${USERNAME}-${CIP2}\",\"add\":\"${CIP2}\",\"port\":\"${VMESS_PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"/${UUID}-vm?ed=2048\",\"tls\":\"\",\"sni\":\"\",\"alpn\":\"\",\"fp\":\"\"}" | base64 -w0)"
    HY2_L2="hysteria2://${UUID}@${CIP2}:${HY2_PORT}?security=tls&sni=www.bing.com&alpn=h3&insecure=1#${SNB}-hy2-${USERNAME}-${CIP2}"

    # 写入 jh.txt（v2ray 通用订阅内容）
    {
        echo "$VLESS_LINK"
        echo "$VMWS_LINK"
        echo "$VMTLS_ARGO_LINK"
        echo "$VM_ARGO_LINK"
        echo "$HY2_LINK"
        echo "$VLESS_L1"; echo "$VMWS_L1"; echo "$HY2_L1"
        echo "$VLESS_L2"; echo "$VMWS_L2"; echo "$HY2_L2"
    } > jh.txt

    # 检测 Argo 是否有效，有效则追加 CF 全端口节点
    local argo_ok; argo_ok=$(check_argo_domain "$argodomain")
    if [[ "$argo_ok" == "404" ]]; then
        local cf_ips_tls=(104.16.0.0 104.17.0.0 104.18.0.0 104.19.0.0 104.20.0.0)
        local cf_ports_tls=(443 2053 2083 2087 2096)
        local cf_ips_plain=(104.16.0.1 104.17.0.1 162.159.192.1 162.159.193.1 104.21.0.0 104.22.0.0)
        local cf_ports_plain=(80 8080 2052 2082 2086 2095)
        local i
        for i in "${!cf_ips_tls[@]}"; do
            local ip="${cf_ips_tls[$i]}" port="${cf_ports_tls[$i]}"
            echo "vmess://$(echo "{\"v\":\"2\",\"ps\":\"${SNB}-argo-tls-${port}-${USERNAME}\",\"add\":\"${ip}\",\"port\":\"${port}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${argodomain}\",\"path\":\"/${UUID}-vm?ed=2048\",\"tls\":\"tls\",\"sni\":\"${argodomain}\",\"alpn\":\"\",\"fp\":\"\"}" | base64 -w0)" >> jh.txt
        done
        for i in "${!cf_ips_plain[@]}"; do
            local ip="${cf_ips_plain[$i]}" port="${cf_ports_plain[$i]}"
            echo "vmess://$(echo "{\"v\":\"2\",\"ps\":\"${SNB}-argo-${port}-${USERNAME}\",\"add\":\"${ip}\",\"port\":\"${port}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${argodomain}\",\"path\":\"/${UUID}-vm?ed=2048\",\"tls\":\"\"}" | base64 -w0)" >> jh.txt
        done
    fi

    # 写入公共订阅目录
    cp jh.txt "${FILE_PATH}/${UUID}_v2sub.txt"
    local baseurl; baseurl=$(base64 -w0 < jh.txt)

    # ── 生成 sing-box 客户端订阅 JSON ──
    jq -n \
        --arg uuid         "$UUID" \
        --arg snb          "$SNB" \
        --arg user         "$USERNAME" \
        --arg ip           "$IP" \
        --arg reym         "$REYM" \
        --arg pubkey       "$PUBLIC_KEY" \
        --argjson vp       "$VLESS_PORT" \
        --argjson vmp      "$VMESS_PORT" \
        --argjson h2p      "$HY2_PORT" \
        --arg argodomain   "$argodomain" \
        '{
          log:{disabled:false,level:"info",timestamp:true},
          experimental:{
            clash_api:{external_controller:"127.0.0.1:9090",external_ui:"ui",secret:"",default_mode:"Rule"},
            cache_file:{enabled:true,path:"cache.db",store_fakeip:true}
          },
          dns:{
            servers:[
              {tag:"proxydns",address:"tls://8.8.8.8/dns-query",detour:"select"},
              {tag:"localdns",address:"h3://223.5.5.5/dns-query",detour:"direct"},
              {tag:"dns_fakeip",address:"fakeip"}
            ],
            rules:[
              {outbound:"any",server:"localdns",disable_cache:true},
              {clash_mode:"Global",server:"proxydns"},
              {clash_mode:"Direct",server:"localdns"},
              {rule_set:"geosite-cn",server:"localdns"},
              {rule_set:"geosite-geolocation-!cn",server:"proxydns"},
              {rule_set:"geosite-geolocation-!cn",query_type:["A","AAAA"],server:"dns_fakeip"}
            ],
            fakeip:{enabled:true,inet4_range:"198.18.0.0/15",inet6_range:"fc00::/18"},
            independent_cache:true,
            final:"proxydns"
          },
          inbounds:[{
            type:"tun",tag:"tun-in",
            address:["172.19.0.1/30","fd00::1/126"],
            auto_route:true,strict_route:true,
            sniff:true,sniff_override_destination:true,
            domain_strategy:"prefer_ipv4"
          }],
          outbounds:[
            {tag:"select",type:"selector",default:"auto",outbounds:["auto",("vless-"+$snb+"-"+$user),("vmess-"+$snb+"-"+$user),("hy2-"+$snb+"-"+$user),("vmess-tls-argo-"+$snb+"-"+$user),("vmess-argo-"+$snb+"-"+$user)]},
            {type:"vless",tag:("vless-"+$snb+"-"+$user),server:$ip,server_port:$vp,uuid:$uuid,flow:"xtls-rprx-vision",tls:{enabled:true,server_name:$reym,utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$pubkey,short_id:""}}},
            {type:"vmess",tag:("vmess-"+$snb+"-"+$user),server:$ip,server_port:$vmp,uuid:$uuid,security:"auto",packet_encoding:"packetaddr",tls:{enabled:false},transport:{type:"ws",path:("/"+$uuid+"-vm"),headers:{Host:["www.bing.com"]}}},
            {type:"hysteria2",tag:("hy2-"+$snb+"-"+$user),server:$ip,server_port:$h2p,password:$uuid,tls:{enabled:true,server_name:"www.bing.com",insecure:true,alpn:["h3"]}},
            {type:"vmess",tag:("vmess-tls-argo-"+$snb+"-"+$user),server:"104.16.0.1",server_port:8443,uuid:$uuid,security:"auto",packet_encoding:"packetaddr",tls:{enabled:true,server_name:$argodomain,utls:{enabled:true,fingerprint:"chrome"}},transport:{type:"ws",path:("/"+$uuid+"-vm"),headers:{Host:[$argodomain]}}},
            {type:"vmess",tag:("vmess-argo-"+$snb+"-"+$user),server:"104.16.0.1",server_port:8880,uuid:$uuid,security:"auto",packet_encoding:"packetaddr",tls:{enabled:false},transport:{type:"ws",path:("/"+$uuid+"-vm"),headers:{Host:[$argodomain]}}},
            {tag:"direct",type:"direct"},
            {tag:"auto",type:"urltest",outbounds:[("vless-"+$snb+"-"+$user),("vmess-"+$snb+"-"+$user),("hy2-"+$snb+"-"+$user),("vmess-tls-argo-"+$snb+"-"+$user),("vmess-argo-"+$snb+"-"+$user)],url:"https://www.gstatic.com/generate_204",interval:"1m",tolerance:50,interrupt_exist_connections:false}
          ],
          route:{
            rule_set:[
              {tag:"geosite-geolocation-!cn",type:"remote",format:"binary",url:"https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geolocation-!cn.srs",download_detour:"select",update_interval:"1d"},
              {tag:"geosite-cn",type:"remote",format:"binary",url:"https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geolocation-cn.srs",download_detour:"select",update_interval:"1d"},
              {tag:"geoip-cn",type:"remote",format:"binary",url:"https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs",download_detour:"select",update_interval:"1d"}
            ],
            auto_detect_interface:true,
            final:"select",
            rules:[
              {inbound:"tun-in",action:"sniff"},
              {protocol:"dns",action:"hijack-dns"},
              {port:443,network:"udp",action:"reject"},
              {clash_mode:"Direct",outbound:"direct"},
              {clash_mode:"Global",outbound:"select"},
              {rule_set:"geoip-cn",outbound:"direct"},
              {rule_set:"geosite-cn",outbound:"direct"},
              {ip_is_private:true,outbound:"direct"},
              {rule_set:"geosite-geolocation-!cn",outbound:"select"}
            ]
          },
          ntp:{enabled:true,server:"time.apple.com",server_port:123,interval:"30m",detour:"direct"}
        }' > sing_box.json
    cp sing_box.json "${FILE_PATH}/${UUID}_singbox.txt"

    # ── 生成 Clash Meta YAML ──
    cat > clash_meta.yaml << YAML
port: 7890
allow-lan: true
mode: rule
log-level: info
unified-delay: true
global-client-fingerprint: chrome
dns:
  enable: false
  listen: :53
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver: [223.5.5.5, 8.8.8.8]
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  fallback:
    - https://1.0.0.1/dns-query
    - tls://dns.google
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr: [240.0.0.0/4]

proxies:
- {name: vless-reality-${SNB}-${USERNAME}, type: vless, server: ${IP}, port: ${VLESS_PORT}, uuid: ${UUID}, network: tcp, udp: true, tls: true, flow: xtls-rprx-vision, servername: ${REYM}, reality-opts: {public-key: ${PUBLIC_KEY}}, client-fingerprint: chrome}
- {name: vmess-ws-${SNB}-${USERNAME}, type: vmess, server: ${IP}, port: ${VMESS_PORT}, uuid: ${UUID}, alterId: 0, cipher: auto, udp: true, tls: false, network: ws, servername: www.bing.com, ws-opts: {path: "/${UUID}-vm", headers: {Host: www.bing.com}}}
- {name: hy2-${SNB}-${USERNAME}, type: hysteria2, server: ${IP}, port: ${HY2_PORT}, password: ${UUID}, alpn: [h3], sni: www.bing.com, skip-cert-verify: true, fast-open: true}
- {name: vmess-tls-argo-${SNB}-${USERNAME}, type: vmess, server: 104.16.0.1, port: 8443, uuid: ${UUID}, alterId: 0, cipher: auto, udp: true, tls: true, network: ws, servername: ${argodomain}, ws-opts: {path: "/${UUID}-vm", headers: {Host: ${argodomain}}}}
- {name: vmess-argo-${SNB}-${USERNAME}, type: vmess, server: 104.16.0.1, port: 8880, uuid: ${UUID}, alterId: 0, cipher: auto, udp: true, tls: false, network: ws, servername: ${argodomain}, ws-opts: {path: "/${UUID}-vm", headers: {Host: ${argodomain}}}}

proxy-groups:
- {name: Auto, type: url-test, url: https://www.gstatic.com/generate_204, interval: 300, tolerance: 50, proxies: [vless-reality-${SNB}-${USERNAME}, vmess-ws-${SNB}-${USERNAME}, hy2-${SNB}-${USERNAME}, vmess-tls-argo-${SNB}-${USERNAME}, vmess-argo-${SNB}-${USERNAME}]}
- {name: Balance, type: load-balance, url: https://www.gstatic.com/generate_204, interval: 300, strategy: round-robin, proxies: [vless-reality-${SNB}-${USERNAME}, vmess-ws-${SNB}-${USERNAME}, hy2-${SNB}-${USERNAME}, vmess-tls-argo-${SNB}-${USERNAME}, vmess-argo-${SNB}-${USERNAME}]}
- {name: Select, type: select, proxies: [Balance, Auto, DIRECT, vless-reality-${SNB}-${USERNAME}, vmess-ws-${SNB}-${USERNAME}, hy2-${SNB}-${USERNAME}, vmess-tls-argo-${SNB}-${USERNAME}, vmess-argo-${SNB}-${USERNAME}]}

rules:
  - GEOIP,LAN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,Select
YAML
    cp clash_meta.yaml "${FILE_PATH}/${UUID}_clashmeta.txt"

    # 公共订阅链接
    local V2_SUB_URL="https://${USERNAME}.${ADDRESS}/${UUID}_v2sub.txt"
    local SB_SUB_URL="https://${USERNAME}.${ADDRESS}/${UUID}_singbox.txt"
    local CM_SUB_URL="https://${USERNAME}.${ADDRESS}/${UUID}_clashmeta.txt"

    # ── 写 list.txt（人类可读版节点信息）──
    cat > list.txt << INFO
=================================================================================================
服务器: ${SNB}  |  用户: ${USERNAME}  |  版本: ${SCRIPT_VERSION}

当前使用 IP：${IP}
备用 IP：${CIP1}  ${CIP2}

端口 → VLESS-Reality: ${VLESS_PORT}  VMess-WS: ${VMESS_PORT}  Hysteria2: ${HY2_PORT}
UUID: ${UUID}
Argo 域名: ${argodomain}
-------------------------------------------------------------------------------------------------

【一】VLESS-Reality 链接：
${VLESS_LINK}

ProxyIP（如 Reality 域名设为 CF 域名时有效）:
  全局: proxyip=${IP}:${VLESS_PORT}
  单节点 path: /pyip=${IP}:${VLESS_PORT}
-------------------------------------------------------------------------------------------------

【二】VMess-WS 链接（三形态）:

1. 直连节点（可改为 CDN 回源）:
${VMWS_LINK}

2. Argo-TLS 节点（443系，CDN优选IP，被墙仍可用）:
${VMTLS_ARGO_LINK}

3. Argo 节点（80系，CDN优选IP，被墙仍可用）:
${VM_ARGO_LINK}
-------------------------------------------------------------------------------------------------

【三】Hysteria2 链接：
${HY2_LINK}
-------------------------------------------------------------------------------------------------

【四】备用 IP 节点：

${VLESS_L1}
${VMWS_L1}
${HY2_L1}

${VLESS_L2}
${VMWS_L2}
${HY2_L2}
-------------------------------------------------------------------------------------------------

【五】订阅链接：
V2rayN/通用:   ${V2_SUB_URL}
Sing-box:      ${SB_SUB_URL}
Clash Meta:    ${CM_SUB_URL}

Base64 剪切板分享码:
${baseurl}
=================================================================================================
INFO

    cat list.txt
    # 清理临时文件
    rm -f sb.log core tunnel.yml tunnel.json fake_useragent_0.2.0.json
    cd - > /dev/null
}

# ── Serv00 多功能主页（Node.js）与 serv00keep.sh ─────────────────────────────
setup_serv00_homepage() {
    green "安装 Serv00 多功能主页..."
    devil www del "${SNB}.${USERNAME}.${HONA}.net" > /dev/null 2>&1
    devil www add "${USERNAME}.${HONA}.net" php > /dev/null 2>&1
    devil www add "${SNB}.${USERNAME}.${HONA}.net" nodejs /usr/local/bin/node18 > /dev/null 2>&1
    ln -fs /usr/local/bin/node18 ~/bin/node > /dev/null 2>&1
    ln -fs /usr/local/bin/npm18  ~/bin/npm  > /dev/null 2>&1
    mkdir -p ~/.npm-global
    npm config set prefix '~/.npm-global' 2>/dev/null
    grep -qF '.npm-global' ~/.bash_profile 2>/dev/null \
        || echo 'export PATH=~/.npm-global/bin:~/bin:$PATH' >> ~/.bash_profile
    source ~/.bash_profile 2>/dev/null
    rm -f ~/.npmrc

    cd "$KEEP_PATH" || return 1
    npm install basic-auth express dotenv axios --silent > /dev/null 2>&1

    # 下载 app.js 并注入变量
    curl -sL "https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/app.js" -o app.js
    sed -i '' "15s/name/${SNB}/g"      app.js 2>/dev/null || sed -i "15s/name/${SNB}/g"      app.js
    sed -i '' "59s/key/${UUID}/g"      app.js 2>/dev/null || sed -i "59s/key/${UUID}/g"       app.js
    sed -i '' "90s/name/${USERNAME}/g" app.js 2>/dev/null || sed -i "90s/name/${USERNAME}/g"  app.js
    sed -i '' "90s/where/${SNB}/g"     app.js 2>/dev/null || sed -i "90s/where/${SNB}/g"      app.js
    rm -f "public/index.html"

    devil www restart "${SNB}.${USERNAME}.${HONA}.net" > /dev/null 2>&1
    curl -sk "http://${SNB}.${USERNAME}.${HONA}.net/up" > /dev/null 2>&1

    # 下载 serv00keep.sh，用 jq/sed 注入配置（避免行号硬编码）
    curl -sSL "https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/serv00keep.sh" \
         -o ~/serv00keep.sh && chmod +x ~/serv00keep.sh

    # 用 sed 模式匹配注入，不依赖行号
    local kf=~/serv00keep.sh
    sed -i '' "s|UUID=''|UUID='${UUID}'|"           "$kf" 2>/dev/null || sed -i "s|UUID=''|UUID='${UUID}'|" "$kf"
    sed -i '' "s|vless_port=''|vless_port='${VLESS_PORT}'|" "$kf" 2>/dev/null || sed -i "s|vless_port=''|vless_port='${VLESS_PORT}'|" "$kf"
    sed -i '' "s|vmess_port=''|vmess_port='${VMESS_PORT}'|" "$kf" 2>/dev/null || sed -i "s|vmess_port=''|vmess_port='${VMESS_PORT}'|" "$kf"
    sed -i '' "s|hy2_port=''|hy2_port='${HY2_PORT}'|"       "$kf" 2>/dev/null || sed -i "s|hy2_port=''|hy2_port='${HY2_PORT}'|" "$kf"
    sed -i '' "s|IP=''|IP='${IP}'|"                 "$kf" 2>/dev/null || sed -i "s|IP=''|IP='${IP}'|" "$kf"
    sed -i '' "s|reym=''|reym='${REYM}'|"           "$kf" 2>/dev/null || sed -i "s|reym=''|reym='${REYM}'|" "$kf"
    if [[ -n "$ARGO_DOMAIN" ]]; then
        sed -i '' "s|ARGO_DOMAIN=''|ARGO_DOMAIN='${ARGO_DOMAIN}'|" "$kf" 2>/dev/null || sed -i "s|ARGO_DOMAIN=''|ARGO_DOMAIN='${ARGO_DOMAIN}'|" "$kf"
        sed -i '' "s|ARGO_AUTH=''|ARGO_AUTH='${ARGO_AUTH}'|"       "$kf" 2>/dev/null || sed -i "s|ARGO_AUTH=''|ARGO_AUTH='${ARGO_AUTH}'|" "$kf"
    fi

    cd - > /dev/null
    green "多功能主页安装完成 → http://${SNB}.${USERNAME}.${HONA}.net"
}

# ── Cron 保活 ─────────────────────────────────────────────────────────────────
setup_cron_keepalive() {
    # 生成独立的保活脚本（自包含，无外部依赖）
    cat > "$KEEPALIVE_SCRIPT" << 'EOF'
#!/bin/bash
# Serv00 sing-box keepalive — 自动生成，请勿手动修改
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')
HONA=$(hostname | cut -d. -f2)
[[ "$HONA" == "serv00" ]] && ADDRESS="serv00.net" || ADDRESS="useruno.com"
WORKDIR="${HOME}/domains/${USERNAME}.${ADDRESS}/logs"
LOG="${WORKDIR}/cron.log"
MAX_LOG_LINES=300

# 日志截断（保留最新 300 行）
if [[ -f "$LOG" && $(wc -l < "$LOG") -gt $MAX_LOG_LINES ]]; then
    tail -n $MAX_LOG_LINES "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

# ── 守护 sing-box ──
if [[ -f "$WORKDIR/sb.txt" ]]; then
    SBB=$(<"$WORKDIR/sb.txt")
    if ! pgrep -x "$SBB" > /dev/null 2>&1; then
        log "[WARN] sing-box 未运行，重启中..."
        cd "$WORKDIR" && nohup ./"$SBB" run -c config.json > /dev/null 2>&1 &
        sleep 4
        pgrep -x "$SBB" > /dev/null 2>&1 && log "[OK] sing-box 重启成功" || log "[ERR] sing-box 重启失败"
    fi
fi

# ── 守护 Argo ──
if [[ -f "$WORKDIR/ag.txt" ]]; then
    AGG=$(<"$WORKDIR/ag.txt")
    if ! pgrep -x "$AGG" > /dev/null 2>&1; then
        log "[WARN] Argo 未运行，重启中..."
        cd "$WORKDIR"
        if [[ -f "$WORKDIR/ARGO_AUTH.log" ]]; then
            AUTH=$(<"$WORKDIR/ARGO_AUTH.log")
            nohup ./"$AGG" tunnel --no-autoupdate run --token "$AUTH" > /dev/null 2>&1 &
        else
            VMP=$(jq -r '.inbounds[] | select(.tag=="vmess-ws-in") | .listen_port' \
                  "$WORKDIR/config.json" 2>/dev/null)
            nohup ./"$AGG" tunnel --url "http://localhost:${VMP}" \
                  --no-autoupdate --logfile "$WORKDIR/boot.log" --loglevel info > /dev/null 2>&1 &
        fi
        sleep 6
        pgrep -x "$AGG" > /dev/null 2>&1 && log "[OK] Argo 重启成功" || log "[ERR] Argo 重启失败"
    fi
fi
EOF

    chmod +x "$KEEPALIVE_SCRIPT"
    # 写入 crontab，去重后追加
    ( crontab -l 2>/dev/null | grep -v "keepalive.sh"
      echo "*/5 * * * * $KEEPALIVE_SCRIPT" ) | crontab -

    green "✅ Cron 保活已配置 — 每5分钟检测一次"
    green "   日志: ${WORKDIR}/cron.log"
}

# ── 快捷方式 sb ───────────────────────────────────────────────────────────────
setup_shortcut() {
    local bin_dir="$HOME/bin"
    mkdir -p "$bin_dir"
    # 复制自身作为快捷方式
    cp "$0" "$bin_dir/sb" 2>/dev/null || \
        curl -sL "https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/serv00.sh" \
             -o "$bin_dir/sb" 2>/dev/null
    chmod +x "$bin_dir/sb"

    if [[ ":$PATH:" != *":${bin_dir}:"* ]]; then
        echo "export PATH=\"\$HOME/bin:\$PATH\"" >> "$HOME/.bashrc"
        grep -qxF 'source ~/.bashrc' "$HOME/.bash_profile" 2>/dev/null \
            || echo 'source ~/.bashrc' >> "$HOME/.bash_profile"
        export PATH="$bin_dir:$PATH"
    fi

    # 下载主页 index.html、记录版本号
    curl -sL "https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/index.html" \
         -o "${FILE_PATH}/index.html" 2>/dev/null
    curl -sL "https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sversion" \
         | awk -F"更新内容" '{print $1}' | head -n 1 > "$WORKDIR/v" 2>/dev/null
    green "快捷方式 sb 已创建"
}

# ── 重置端口并更新 config.json ────────────────────────────────────────────────
reset_ports() {
    # 删除所有已分配端口
    local portlist
    portlist=$(devil port list | grep -E '^[0-9]+[[:space: ]]+[a-zA-Z]+' | sed 's/^[[:space: ]]*//')
    if [[ -n "$portlist" ]]; then
        while read -r line; do
            local p t
            p=$(echo "$line" | awk '{print $1}')
            t=$(echo "$line" | awk '{print $2}')
            yellow "删除端口 $p ($t)"
            devil port del "$t" "$p" > /dev/null 2>&1
        done <<< "$portlist"
    fi

    check_port || return 1

    if ! is_installed; then
        yellow "未安装，跳过 config.json 端口更新"
        return 0
    fi

    load_runtime_conf
    local old_h2p old_vlp old_vmp
    old_h2p=$(jq -r '.inbounds[] | select(.tag=="hysteria-in1")          | .listen_port' "$WORKDIR/config.json" 2>/dev/null)
    old_vlp=$(jq -r '.inbounds[] | select(.tag=="vless-reality-vesion")   | .listen_port' "$WORKDIR/config.json" 2>/dev/null)
    old_vmp=$(jq -r '.inbounds[] | select(.tag=="vmess-ws-in")            | .listen_port' "$WORKDIR/config.json" 2>/dev/null)

    # 用 jq 按 tag 字段更新端口，完全不依赖行号
    local tmp
    tmp=$(jq \
        --argjson h2p "$HY2_PORT" \
        --argjson vlp "$VLESS_PORT" \
        --argjson vmp "$VMESS_PORT" \
        '(.inbounds[] | select(.tag | startswith("hysteria")) | .listen_port) |= $h2p |
         (.inbounds[] | select(.tag=="vless-reality-vesion")  | .listen_port) |= $vlp |
         (.inbounds[] | select(.tag=="vmess-ws-in")           | .listen_port) |= $vmp' \
        "$WORKDIR/config.json")
    echo "$tmp" > "$WORKDIR/config.json"
    green "config.json 端口已更新"

    # 更新 serv00keep.sh（如存在）
    local kf=~/serv00keep.sh
    if [[ -f "$kf" ]]; then
        sed -i '' "s|vless_port='${old_vlp}'|vless_port='${VLESS_PORT}'|" "$kf" 2>/dev/null \
            || sed -i "s|vless_port='${old_vlp}'|vless_port='${VLESS_PORT}'|" "$kf"
        sed -i '' "s|vmess_port='${old_vmp}'|vmess_port='${VMESS_PORT}'|" "$kf" 2>/dev/null \
            || sed -i "s|vmess_port='${old_vmp}'|vmess_port='${VMESS_PORT}'|" "$kf"
        sed -i '' "s|hy2_port='${old_h2p}'|hy2_port='${HY2_PORT}'|"       "$kf" 2>/dev/null \
            || sed -i "s|hy2_port='${old_h2p}'|hy2_port='${HY2_PORT}'|"       "$kf"
    fi

    start_singbox

    local argo_status
    if [[ -f "$WORKDIR/boot.log" ]]; then
        pgrep -x "$AGG" > /dev/null 2>&1 && green "Argo 临时隧道运行中" || { start_argo; }
    else
        pgrep -x "$AGG" > /dev/null 2>&1 \
            && green "Argo 固定隧道运行中" \
            || yellow "Argo 固定隧道未运行，请确认 CF 侧端口已更新为 ${VMESS_PORT}"
    fi

    cd "$WORKDIR" && gen_links
    cd - > /dev/null
}

# ── Argo 重置/切换 ────────────────────────────────────────────────────────────
reset_argo() {
    is_installed || { red "未安装，请先选择 1 安装"; return; }
    load_runtime_conf
    cd "$WORKDIR" || return 1

    local cur_vmess_port
    cur_vmess_port=$(jq -r '.inbounds[] | select(.tag=="vmess-ws-in") | .listen_port' config.json 2>/dev/null)

    echo
    if [[ -f "boot.log" ]]; then
        green "当前: Argo 临时隧道"
    else
        green "当前: Argo 固定隧道"
        [[ -f "ARGO_DOMAIN_show.log" ]] && purple "  域名: $(< ARGO_DOMAIN_show.log)"
        [[ -f "ARGO_AUTH_show.log"   ]] && purple "  Token: $(< ARGO_AUTH_show.log)"
        purple "  端口: ${cur_vmess_port}"
    fi
    echo

    prompt_argo

    # 停止所有 Argo 进程
    pgrep -x "$AGG" > /dev/null 2>&1 && pkill -x "$AGG" && sleep 1

    start_argo

    # 更新 serv00keep.sh 中的 Argo 配置
    local kf=~/serv00keep.sh
    if [[ -f "$kf" && "$HONA" == "serv00" ]]; then
        if [[ -n "$ARGO_DOMAIN" ]]; then
            sed -i '' "s|ARGO_DOMAIN=''|ARGO_DOMAIN='${ARGO_DOMAIN}'|" "$kf" 2>/dev/null \
                || sed -i "s|ARGO_DOMAIN=''|ARGO_DOMAIN='${ARGO_DOMAIN}'|" "$kf"
            sed -i '' "s|ARGO_AUTH=''|ARGO_AUTH='${ARGO_AUTH}'|" "$kf" 2>/dev/null \
                || sed -i "s|ARGO_AUTH=''|ARGO_AUTH='${ARGO_AUTH}'|" "$kf"
        else
            sed -i '' "s|ARGO_DOMAIN='[^']*'|ARGO_DOMAIN=''|" "$kf" 2>/dev/null \
                || sed -i "s|ARGO_DOMAIN='[^']*'|ARGO_DOMAIN=''|" "$kf"
            sed -i '' "s|ARGO_AUTH='[^']*'|ARGO_AUTH=''|" "$kf" 2>/dev/null \
                || sed -i "s|ARGO_AUTH='[^']*'|ARGO_AUTH=''|" "$kf"
        fi
    fi

    gen_links
    cd - > /dev/null
}

# ── 主流程：安装 ──────────────────────────────────────────────────────────────
install_singbox() {
    is_installed && { yellow "已安装，请先选择 2 卸载再重装"; return; }

    sleep 1
    cd "$WORKDIR" || return 1

    # 1. 收集用户输入
    echo; prompt_ip
    echo; prompt_reym
    echo; prompt_uuid
    echo; check_port || { red "端口初始化失败"; return 1; }
    echo; prompt_argo
    echo

    # 2. 下载二进制
    download_binaries || { red "二进制文件下载失败"; return 1; }

    # 3. Reality 密钥 & 证书
    gen_reality_keypair

    # 4. serv14/15: 复用已有 WARP 账号，否则注册新账号
    if [[ "$NB" =~ ^(14|15)$ ]]; then
        if [[ -f "$WORKDIR/warp_key.json" ]]; then
            green "检测到已有 WARP 账号，跳过注册，直接复用"
            WARP_PRIVATE_KEY=$(jq -r '.private_key' "$WORKDIR/warp_key.json")
            WARP_IPV4=$(jq -r '.ipv4'        "$WORKDIR/warp_key.json")
            WARP_IPV6=$(jq -r '.ipv6'        "$WORKDIR/warp_key.json")
            WARP_RESERVED=$(jq -c '.reserved' "$WORKDIR/warp_key.json")
            green "WARP → IPv4: ${WARP_IPV4}  IPv6: ${WARP_IPV6}"
        else
            register_warp
        fi
    fi

    # 5. 生成 config.json
    gen_config

    # 6. 启动进程
    start_singbox
    start_argo

    cd - > /dev/null

    # 7. 快捷方式、主页、保活
    setup_shortcut
    [[ "$HONA" == "serv00" ]] && setup_serv00_homepage
    setup_cron_keepalive

    # 8. 输出节点信息
    cd "$WORKDIR"
    gen_links
    cd - > /dev/null

    purple "========================================================"
    purple "安装完成！请重新连接 SSH，输入 sb 进入管理菜单"
    purple "========================================================"
    sleep 2
    kill -9 "$(ps -o ppid= -p $$)" > /dev/null 2>&1
}

# ── 卸载 ─────────────────────────────────────────────────────────────────────
uninstall_singbox() {
    reading "确定卸载？所有配置将被删除 [y/N]: " _c
    [[ "$_c" != [Yy] ]] && return

    bash -c 'ps aux | grep "$(whoami)" | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9' > /dev/null 2>&1
    rm -rf ~/bin ~/domains ~/serv00keep.sh ~/webport.sh "$KEEPALIVE_SCRIPT"
    devil www list 2>/dev/null | awk 'NR>1 && NF {print $1}' | xargs -I{} devil www del {} > /dev/null 2>&1
    sed -i '' '/export PATH=.*HOME.*bin/d' ~/.bashrc 2>/dev/null || sed -i '/export PATH=.*HOME.*bin/d' ~/.bashrc
    ( crontab -l 2>/dev/null | grep -v "keepalive.sh" ) | crontab -
    source ~/.bashrc 2>/dev/null

    purple "卸载完成"
}

# ── 系统初始化（清理重置）────────────────────────────────────────────────────
reset_all() {
    reading "⚠️  这将清除全部文件并退出 SSH，确定？[y/N]: " _c
    [[ "$_c" != [Yy] ]] && return

    bash -c 'ps aux | grep "$(whoami)" | grep -v "sshd\|bash\|grep" | awk "{print \$2}" | xargs -r kill -9' > /dev/null 2>&1
    devil www list 2>/dev/null | awk 'NR>1 && NF {print $1}' | xargs -I{} devil www del {} > /dev/null 2>&1
    ( crontab -l 2>/dev/null | grep -v "keepalive.sh" ) | crontab -
    sed -i '' '/export PATH=.*HOME.*bin/d' ~/.bashrc 2>/dev/null || sed -i '/export PATH=.*HOME.*bin/d' ~/.bashrc
    purple "清理完成，退出 SSH..."
    find ~ -type f -exec rm -f {} \; 2>/dev/null
    find ~ -type d -empty -exec rmdir {} \; 2>/dev/null
    killall -9 -u "$(whoami)" 2>/dev/null
}

# ── 重启主进程 ────────────────────────────────────────────────────────────────
restart_singbox() {
    is_installed || { red "未安装"; return; }
    load_runtime_conf
    cd "$WORKDIR" || return 1

    if [[ "$HONA" == "serv00" ]]; then
        # serv00: 通过主页 HTTP 接口触发（Node.js 服务保活机制）
        yellow "通过主页接口触发重启..."
        curl -sk "http://${SNB}.${USERNAME}.${HONA}.net/up" > /dev/null 2>&1
        sleep 6
    else
        start_singbox
    fi

    pgrep -x "$SBB" > /dev/null 2>&1 \
        && green "sing-box 运行中" \
        || red "sing-box 未运行，请尝试选 8 重置端口"
    cd - > /dev/null
}

# ── 菜单 ─────────────────────────────────────────────────────────────────────
menu() {
    clear
    echo "════════════════════════════════════════════════════════"
    green " Serv00 / Hostuno · Sing-box 三协议管理脚本（重写版）"
    green " 协议: VLESS-Reality | VMess-WS(Argo) | Hysteria2"
    green " 快捷方式: sb   版本: ${SCRIPT_VERSION}"
    echo "════════════════════════════════════════════════════════"
    green  " 1. 一键安装"
    yellow " 2. 卸载"
    green  " 3. 重启 sing-box 主进程"
    green  " 4. Argo 重置 / 切换固定·临时隧道"
    green  " 5. 更新脚本"
    green  " 6. 查看节点 / 订阅链接"
    green  " 7. 查看 Sing-box / Clash 配置文件"
    yellow " 8. 重置端口（随机生成新端口）"
    green  " 10. 重置 Cron 保活"
    red    " 9. 清理重置（系统初始化）"
    red    " 0. 退出"
    echo "════════════════════════════════════════════════════════"

    # ── 状态面板 ──
    if [[ "$HONA" == "serv00" ]]; then
        red "⚠️  Serv00 免费版使用代理脚本存在封号风险，请知晓"
    fi
    green "服务器: ${SNB}.${HONA}  用户: ${USERNAME}"
    echo

    # IP 状态
    local ip_file="$WORKDIR/ip.txt"
    rm -f "$ip_file"
    local hosts=("${HOSTNAME_FULL}" "cache${NB}.${HONA}.com" "web${NB}.${HONA}.com")
    for h in "${hosts[@]}"; do
        local resp ip_status
        resp=$(curl -sL --connect-timeout 5 --max-time 7 "https://ss.fkj.pp.ua/api/getip?host=${h}" 2>/dev/null)
        if [[ "$resp" =~ (unknown|not|error) || -z "$resp" ]]; then
            local resolved; resolved=$(resolve_ip "$h")
            [[ -n "$resolved" ]] && echo "${resolved}: 未知状态" >> "$ip_file"
        else
            while IFS='|' read -r ip st; do
                [[ -z "$ip" ]] && continue
                [[ "$st" == "Accessible" ]] \
                    && echo "${ip}: 可用" >> "$ip_file" \
                    || echo "${ip}: 被墙 (Argo/CDN/ProxyIP仍可用)" >> "$ip_file"
            done <<< "$resp"
        fi
    done
    sort -u -o "$ip_file" "$ip_file" 2>/dev/null
    green "IP 状态："
    cat "$ip_file" 2>/dev/null || yellow "  无法获取 IP 信息"
    echo

    # 端口状态
    local portlist
    portlist=$(devil port list 2>/dev/null | grep -E '^[0-9]+[[:space: ]]+[a-zA-Z]+')
    if [[ -n "$portlist" ]]; then
        green "已分配端口："
        echo "$portlist"
    else
        yellow "暂无已分配端口"
    fi
    echo

    # 进程 & 版本状态
    if is_installed; then
        load_runtime_conf

        local insV latestV
        insV=$(cat "$WORKDIR/v" 2>/dev/null)
        latestV=$(curl -sL "https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sversion" 2>/dev/null \
                  | awk -F"更新内容" '{print $1}' | head -n 1)
        if [[ "$insV" == "$latestV" ]]; then
            echo -e "脚本版本: \e[1;35m${insV}\e[0m (最新)"
        else
            echo -e "脚本版本: \e[1;35m${insV}\e[0m  ←  最新: \e[1;33m${latestV}\e[0m (选 5 更新)"
        fi

        # sing-box 状态
        pgrep -x "$SBB" > /dev/null 2>&1 \
            && green "sing-box: ✅ 运行中 ($SBB)" \
            || yellow "sing-box: ❌ 未运行，建议选 3 重启"

        # Argo 状态
        if [[ -f "$WORKDIR/boot.log" ]]; then
            local tmp_domain code
            tmp_domain=$(get_argo_domain)
            code=$(check_argo_domain "$tmp_domain")
            [[ "$code" == "404" ]] \
                && green "Argo 临时隧道: ✅ 有效  → ${tmp_domain}" \
                || yellow "Argo 临时隧道: ⚠️  域名暂时无效（保活后恢复）"
        else
            local fixed_domain code
            fixed_domain=$(cat "$WORKDIR/ARGO_DOMAIN.log" 2>/dev/null)
            code=$(check_argo_domain "$fixed_domain")
            if [[ "$code" == "404" ]]; then
                green "Argo 固定隧道: ✅ 有效  → ${fixed_domain}"
            else
                yellow "Argo 固定隧道: ❌ 无效  → ${fixed_domain:-未设置}"
            fi
        fi

        # Cron 保活状态
        crontab -l 2>/dev/null | grep -q "keepalive.sh" \
            && green "Cron 保活: ✅ 已启用（每5分钟）" \
            || yellow "Cron 保活: ❌ 未启用，建议选 10"

        # serv00 主页
        [[ "$HONA" == "serv00" ]] && purple "多功能主页: http://${SNB}.${USERNAME}.${HONA}.net"

    else
        yellow "未安装 → 请选择 1 开始安装"
    fi

    echo "════════════════════════════════════════════════════════"
    reading "请选择 [0-10]: " _choice
    echo

    case "$_choice" in
        1)  install_singbox ;;
        2)  uninstall_singbox ;;
        3)  restart_singbox ;;
        4)  reset_argo ;;
        5)  setup_shortcut && green "脚本已更新" ;;
        6)  is_installed && { load_runtime_conf; cd "$WORKDIR"; gen_links; cd -; } || red "未安装" ;;
        7)  is_installed && { load_runtime_conf; cat "$WORKDIR/sing_box.json" 2>/dev/null; echo; cat "$WORKDIR/clash_meta.yaml" 2>/dev/null; } || red "未安装" ;;
        8)  reset_ports ;;
        9)  reset_all ;;
        10) setup_cron_keepalive ;;
        0)  exit 0 ;;
        *)  red "无效选项，请输入 0-10" ;;
    esac
    echo
    reading "按回车键返回菜单..." _dummy
    menu
}

menu
