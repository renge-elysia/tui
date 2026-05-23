#!/usr/bin/env bash

### ===== 配置参数 =====
WORK_DIR="/usr/local/tuic"
BIN="${WORK_DIR}/tuic-server"
CONF="${WORK_DIR}/config.json"
SERVICE_NAME="tuic"
### =====================

GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# 权限检查
[[ "$(id -u)" != "0" ]] && { echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; }

# 环境判断
if [ -f /etc/alpine-release ]; then
    OS="alpine"
elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
    OS="debian"
else
    echo -e "${RED}❌ 不支持的系统${NC}"; exit 1
fi

# 检查服务状态
get_status() {
    if command -v systemctl >/dev/null; then
        if systemctl is-active --quiet ${SERVICE_NAME}; then
            echo -e "${GREEN}正在运行${NC}"
        else
            echo -e "${RED}未安装或未运行${NC}"
        fi
    else
        if rc-service ${SERVICE_NAME} status 2>/dev/null | grep -q "started"; then
            echo -e "${GREEN}正在运行${NC}"
        else
            echo -e "${RED}未安装或未运行${NC}"
        fi
    fi
}

# 安装基础依赖
install_dependencies() {
    echo -e "${YELLOW}▶ 正在检查并安装必要依赖...${NC}"
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache curl openssl bash openrc jq
    else
        apt update -y && apt install -y curl openssl jq
    fi
}

# 重启服务
restart_service() {
    if command -v systemctl >/dev/null; then
        systemctl restart ${SERVICE_NAME}
    else
        rc-service ${SERVICE_NAME} restart
    fi
}

# 获取并显示配置信息
show_info() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ TUIC 未安装或配置文件不存在${NC}"; return
    fi
    
    SERVER_ADDR=$(jq -r '.server' "$CONF")
    PORT=$(echo $SERVER_ADDR | rev | cut -d: -f1 | rev)
    UUID=$(jq -r '.users | keys[0]' "$CONF")
    PASS=$(jq -r ".users.\"$UUID\"" "$CONF")
    
    echo -e "${YELLOW}正在检测公网 IP 地址...${NC}"
    # 增加 -m 7 全局超时，防止彻底卡死
    IP4=$(curl -s4 -m 7 --connect-timeout 5 ip.sb || curl -s4 -m 7 --connect-timeout 5 icanhazip.com || echo "")
    IP6=$(curl -s6 -m 7 --connect-timeout 5 ip.sb || curl -s6 -m 7 --connect-timeout 5 icanhazip.com || echo "")

    echo -e "\n${GREEN}========== TUIC 配置信息 ==========${NC}"
    echo -e "🌐 IPv4地址: ${YELLOW}$IP4${NC}"
    echo -e "🌐 IPv6地址: ${YELLOW}$IP6${NC}"
    echo -e "📌 UUID: ${YELLOW}$UUID${NC}"
    echo -e "🔐 密码: ${YELLOW}$PASS${NC}"
    echo -e "🎲 端口: ${YELLOW}$PORT${NC}"
    
    if [[ -n "$IP4" ]]; then
        echo -e "\n${GREEN}📎 TUIC 节点链接 (IPv4):${NC}"
        echo -e "${YELLOW}tuic://$UUID:$PASS@$IP4:$PORT?congestion_control=bbr&alpn=h3&insecure=1&sni=www.bing.com#TUIC_V4${NC}"
    fi
    
    if [[ -n "$IP6" ]]; then
        echo -e "\n${GREEN}📎 TUIC 节点链接 (IPv6):${NC}"
        echo -e "${YELLOW}tuic://$UUID:$PASS@[$IP6]:$PORT?congestion_control=bbr&alpn=h3&insecure=1&sni=www.bing.com#TUIC_V6${NC}"
    fi
    echo -e "${GREEN}=======================================${NC}\n"
}

# 修改端口
change_port() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 请先安装 TUIC${NC}"; return
    fi
    
    OLD_ADDR=$(jq -r '.server' "$CONF")
    OLD_PORT=$(echo $OLD_ADDR | rev | cut -d: -f1 | rev)
    HOST=$(echo $OLD_ADDR | rev | cut -d: -f2- | rev)
    
    echo -e "当前监听端口为: ${YELLOW}$OLD_PORT${NC}"
    echo -ne "${GREEN}请输入新端口 (直接回车则随机生成): ${NC}"
    read NEW_PORT
    
    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 50000 ) + 10000 ))

    if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        echo -e "${RED}❌ 输入无效${NC}"; return
    fi

    # 临时文件处理，防止由于 jq 报错导致配置文件清空或残留
    tmp=$(mktemp)
    if jq --arg addr "${HOST}:${NEW_PORT}" '.server = $addr' "$CONF" > "$tmp"; then
        mv "$tmp" "$CONF"
    else
        echo -e "${RED}❌ 配置文件修改失败${NC}"
        rm -f "$tmp"
        return
    fi

    # 清除旧端口放行，添加新端口放行
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "$OLD_PORT"/udp 2>/dev/null || true
        ufw allow "$NEW_PORT"/udp
    elif command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p udp --dport "$OLD_PORT" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport "$NEW_PORT" -j ACCEPT
    fi
    
    restart_service
    echo -e "${GREEN}✅ 端口已成功更改为 $NEW_PORT${NC}"
    show_info
}

# 安装 TUIC
install_tuic() {
    install_dependencies
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) TUIC_ARCH="x86_64" ;;
        aarch64|arm64) TUIC_ARCH="aarch64" ;;
        *) echo "❌ 不支持架构: $ARCH"; exit 1 ;;
    esac

    mkdir -p $WORK_DIR
    echo -e "${YELLOW}▶ 正在下载 TUIC Server...${NC}"
    URL="https://github.com/Itsusinn/tuic/releases/latest/download/tuic-server-${TUIC_ARCH}-linux-musl"
    if ! curl -L -o $BIN "$URL"; then
        echo -e "${RED}❌ 下载失败，请检查网络${NC}"; exit 1
    fi
    chmod +x $BIN

    echo -e "\n${GREEN}--- 基础配置 ---${NC}"
    echo -ne "${GREEN}请输入监听端口 (直接回车则随机生成): ${NC}"
    read INPUT_PORT

    if [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] && [ "$INPUT_PORT" -ge 1 ] && [ "$INPUT_PORT" -le 65535 ]; then
        PORT=$INPUT_PORT
    else
        PORT=$(( ( RANDOM % 50000 ) + 10000 ))
        echo -e "${YELLOW}使用随机端口: $PORT${NC}"
    fi

    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASS=$(openssl rand -hex 4)
    
    # 修复因为无 IPv6 环境导致 set -e 退出的问题
    BIND_ADDR="0.0.0.0"
    if ip -6 addr 2>/dev/null | grep -q "global"; then
        BIND_ADDR="[::]"
    fi

    cat > $CONF <<EOF
{
  "server": "${BIND_ADDR}:${PORT}",
  "users": {
    "${UUID}": "${PASS}"
  },
  "congestion_control": "bbr",
  "auth_timeout": "3s",
  "zero_rtt_handshake": false,
  "tls": {
    "certificate": "${WORK_DIR}/cert.pem",
    "private_key": "${WORK_DIR}/key.pem",
    "alpn": ["h3"]
  }
}
EOF

    # 证书生成失败处理
    if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${WORK_DIR}/key.pem" -out "${WORK_DIR}/cert.pem" \
        -subj "/CN=www.bing.com" -days 3650 -nodes 2>/dev/null; then
        echo -e "${RED}❌ 自签证书生成失败${NC}"
        exit 1
    fi

    if command -v systemctl >/dev/null; then
        cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=TUIC Server
After=network.target
[Service]
ExecStart=${BIN} -c ${CONF}
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ${SERVICE_NAME}
    else
        cat > /etc/init.d/${SERVICE_NAME} <<EOF
#!/sbin/openrc-run
description="TUIC Server"
command="${BIN}"
command_args="-c ${CONF}"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background=true
depend() {
    need net
}
EOF
        chmod +x /etc/init.d/${SERVICE_NAME}
        rc-update add ${SERVICE_NAME} default
    fi

    # 放行初始端口
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$PORT"/udp >/dev/null 2>&1
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT >/dev/null 2>&1
    fi

    restart_service
    sleep 2 # 给程序启动的时间

    # 启动状态校验
    if command -v systemctl >/dev/null; then
        if ! systemctl is-active --quiet ${SERVICE_NAME}; then
            echo -e "${RED}❌ TUIC 启动失败，请检查端口是否被占用或查看日志。${NC}"
            return
        fi
    else
        if ! rc-service ${SERVICE_NAME} status 2>/dev/null | grep -q "started"; then
            echo -e "${RED}❌ TUIC 启动失败，请检查端口是否被占用或查看日志。${NC}"
            return
        fi
    fi

    echo -e "${GREEN}✅ TUIC 安装并配置完成${NC}"
    show_info
}

# 卸载
uninstall_tuic() {
    # 尝试读取端口以清理防火墙规则
    if [ -f "$CONF" ]; then
        OLD_ADDR=$(jq -r '.server' "$CONF" 2>/dev/null)
        OLD_PORT=$(echo $OLD_ADDR | rev | cut -d: -f1 | rev 2>/dev/null)
        if [[ -n "$OLD_PORT" ]]; then
            if command -v ufw >/dev/null 2>&1; then
                ufw delete allow "$OLD_PORT"/udp 2>/dev/null || true
            elif command -v iptables >/dev/null 2>&1; then
                iptables -D INPUT -p udp --dport "$OLD_PORT" -j ACCEPT 2>/dev/null || true
            fi
        fi
    fi

    if command -v systemctl >/dev/null; then
        systemctl stop ${SERVICE_NAME} || true
        systemctl disable ${SERVICE_NAME} || true
        rm -f /etc/systemd/system/${SERVICE_NAME}.service
        systemctl daemon-reload
    else
        rc-service ${SERVICE_NAME} stop || true
        rc-update del ${SERVICE_NAME} || true
        rm -f /etc/init.d/${SERVICE_NAME}
    fi
    rm -rf $WORK_DIR
    echo -e "${GREEN}✅ 卸载成功${NC}"
}

# 按任意键返回
read_return() {
    echo -e "\n${YELLOW}按任意键返回主菜单...${NC}"
    read -n 1 -s -r -p ""
}

# --- 核心菜单逻辑 ---
while true; do
    clear
    STATUS=$(get_status)
    echo -e "${GREEN}===================================${NC}"
    echo -e "  TUIC 一键管理脚本"
    echo -e "  当前系统：${CYAN}$OS${NC}"
    echo -e "  TUIC状态：$STATUS"
    echo -e "${GREEN}===================================${NC}"
    echo -e "  ${CYAN}[1]${NC}  安装 TUIC"
    echo -e "  ${CYAN}[2]${NC}  查看配置节点链接"
    echo -e "  ${CYAN}[3]${NC}  更改监听端口"
    echo -e "  ${CYAN}[4]${NC}  重启服务"
    echo -e "  ${CYAN}[5]${NC}  卸载 TUIC"
    echo -e "  ${CYAN}[0]${NC}  退出脚本"
    echo -e "${GREEN}===================================${NC}"
    echo -ne " 请输入数字选择 [0-5]: "
    read choice

    case $choice in
        1)
            install_tuic
            read_return
            ;;
        2)
            show_info
            read_return
            ;;
        3)
            change_port
            read_return
            ;;
        4)
            restart_service && echo -e "${GREEN}✅ 服务已重启${NC}"
            read_return
            ;;
        5)
            uninstall_tuic
            read_return
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}❌ 无效选择${NC}"
            sleep 1
            ;;
    esac
done
