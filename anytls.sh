#!/usr/bin/env bash
set -e

### ===== 配置参数 =====
WORK_DIR="/usr/local/anytls"
BIN="${WORK_DIR}/anytls"
CONF="${WORK_DIR}/config.json" # 仅作本脚本记录状态使用
SERVICE_NAME="anytls"
### =====================

# 终端颜色设置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 权限检查
[[ "$(id -u)" != "0" ]] && { echo -e "${RED}错误: 请使用 root 运行${NC}"; exit 1; }

# 环境判断与限制
if [ -f /etc/alpine-release ]; then
    OS="alpine"
elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
    OS="debian"
else
    echo -e "${RED}错误: 当前脚本仅支持 Debian/Ubuntu 或 Alpine 系统${NC}"
    exit 1
fi

# 检查服务状态
get_status() {
    if command -v systemctl >/dev/null; then
        if systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
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

install_dependencies() {
    echo -e "${YELLOW}▶ 正在检查并安装必要依赖...${NC}"
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache curl openssl bash openrc jq unzip
    else
        apt update -y && apt install -y curl openssl jq unzip
    fi
}

update_service_config() {
    local port=$1
    local pass=$2
    local bind_addr="0.0.0.0"

    if command -v systemctl >/dev/null; then
        cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=AnyTLS-Go Server
After=network.target

[Service]
ExecStart=${BIN} -l ${bind_addr}:${port} -p ${pass}
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        cat > /etc/init.d/${SERVICE_NAME} <<EOF
#!/sbin/openrc-run
description="AnyTLS-Go Server"
command="${BIN}"
command_args="-l ${bind_addr}:${port} -p ${pass}"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background=true

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/${SERVICE_NAME}
    fi
}

restart_service() {
    if command -v systemctl >/dev/null; then
        systemctl restart ${SERVICE_NAME}
    else
        rc-service ${SERVICE_NAME} restart
    fi
}

# 防火墙端口管理
manage_firewall() {
    local port=$1
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$port"/tcp >/dev/null 2>&1
        ufw allow "$port"/udp >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port="$port"/udp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
}

show_info() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 配置文件不存在，请先安装 AnyTLS${NC}"; return
    fi
    
    LISTEN=$(jq -r '.listen' "$CONF")
    PORT=$(echo $LISTEN | rev | cut -d: -f1 | rev)
    PASS=$(jq -r '.password' "$CONF")
    
    echo -e "${YELLOW}正在检测公网 IP...${NC}"
    # 忽略获取IP可能带来的报错
    IP4=$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 icanhazip.com || echo "")
    IP6=$(curl -s6 --connect-timeout 5 ip.sb || curl -s6 --connect-timeout 5 icanhazip.com || echo "")

    echo -e "\n${GREEN}========== AnyTLS 配置信息 ==========${NC}"
    echo -e "🔐 密码: ${YELLOW}$PASS${NC}"
    echo -e "🎲 端口: ${YELLOW}$PORT${NC}"
    
    if [[ -n "$IP4" ]]; then
        echo -e "\n${CYAN}📎 IPv4 链接:${NC}"
        echo -e "${YELLOW}anytls://$PASS@$IP4:$PORT?insecure=1#AnyTLS_v4${NC}"
    fi
    
    if [[ -n "$IP6" ]]; then
        echo -e "\n${CYAN}📎 IPv6 链接:${NC}"
        echo -e "${YELLOW}anytls://$PASS@[$IP6]:$PORT?insecure=1#AnyTLS_v6${NC}"
    fi
    echo -e "${GREEN}=======================================${NC}\n"
}

change_port() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 请先安装 AnyTLS${NC}"; return
    fi

    OLD_LISTEN=$(jq -r '.listen' "$CONF")
    OLD_PORT=$(echo $OLD_LISTEN | rev | cut -d: -f1 | rev)
    PASS=$(jq -r '.password' "$CONF")

    echo -e "当前监听端口: ${YELLOW}$OLD_PORT${NC}"
    echo -ne "${GREEN}请输入新端口 (回车随机): ${NC}"
    read NEW_PORT

    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 50000 ) + 10000 ))

    if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        echo -e "${RED}❌ 输入无效${NC}"; return
    fi

    tmp=$(mktemp)
    jq --arg nl "0.0.0.0:$NEW_PORT" '.listen = $nl' "$CONF" > "$tmp" && mv "$tmp" "$CONF"

    update_service_config "$NEW_PORT" "$PASS"
    manage_firewall "$NEW_PORT"
    restart_service

    echo -e "${GREEN}✅ 端口已更改为 $NEW_PORT (注意：旧端口的防火墙规则需手动清理)${NC}"
    show_info
}

install_anytls() {
    install_dependencies
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) AT_ARCH="amd64" ;;
        aarch64|arm64) AT_ARCH="arm64" ;;
        *) echo -e "${RED}❌ 不支持架构: $ARCH${NC}"; exit 1 ;;
    esac

    mkdir -p $WORK_DIR
    echo -e "${YELLOW}▶ 正在从 GitHub 下载最新版本...${NC}"
    
    LATEST_JSON=$(curl -s "https://api.github.com/repos/anytls/anytls-go/releases/latest")
    DOWNLOAD_URL=$(echo "$LATEST_JSON" | jq -r ".assets[] | select(.name | contains(\"linux_${AT_ARCH}\") and endswith(\".zip\")) | .browser_download_url")

    # 检查是否成功获取下载链接 (防 GitHub API 限流)
    if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
        echo -e "${RED}❌ 获取下载链接失败！可能是 GitHub API 速率限制，请稍后再试。${NC}"
        exit 1
    fi

    curl -L -o "${WORK_DIR}/anytls.zip" "$DOWNLOAD_URL"
    unzip -o "${WORK_DIR}/anytls.zip" -d $WORK_DIR
    
    if [ -f "${WORK_DIR}/anytls-server" ]; then
        mv "${WORK_DIR}/anytls-server" $BIN
    fi
    chmod +x $BIN
    rm -f "${WORK_DIR}/anytls.zip" "${WORK_DIR}/anytls-client" "${WORK_DIR}/readme.md"

    echo -ne "\n${GREEN}请输入监听端口 (回车随机): ${NC}"
    read INPUT_PORT
    if [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] && [ "$INPUT_PORT" -ge 1 ] && [ "$INPUT_PORT" -le 65535 ]; then
        PORT=$INPUT_PORT
    else
        PORT=$(( ( RANDOM % 50000 ) + 10000 ))
    fi

    PASS=$(openssl rand -hex 4)

    # 记录状态到本地文件
    cat > $CONF <<EOF
{
  "listen": "0.0.0.0:${PORT}",
  "password": "${PASS}"
}
EOF

    update_service_config "$PORT" "$PASS"
    manage_firewall "$PORT"
    
    if command -v systemctl >/dev/null; then
        systemctl enable ${SERVICE_NAME}
    else
        rc-update add ${SERVICE_NAME} default
    fi

    restart_service
    echo -e "${GREEN}✅ AnyTLS 安装完成！${NC}"
    show_info
}

# 辅助函数：按任意键返回
read_return() {
    echo -e "\n${YELLOW}按任意键返回主菜单...${NC}"
    read -n 1 -s -r -p ""
}

# 主循环
while true; do
    clear
    STATUS=$(get_status)
    echo -e "${GREEN}============================================${NC}"
    echo -e "  AnyTLS 一键管理脚本"
    echo -e "  当前系统：${CYAN}$OS${NC}"
    echo -e "  服务状态：$STATUS"
    echo -e "${GREEN}============================================${NC}"
    echo -e "  ${CYAN}[1]${NC}  安装 AnyTLS"
    echo -e "  ${CYAN}[2]${NC}  查看配置节点链接"
    echo -e "  ${CYAN}[3]${NC}  修改监听端口"
    echo -e "  ${CYAN}[4]${NC}  重启服务"
    echo -e "  ${CYAN}[5]${NC}  卸载 AnyTLS"
    echo -e "  ${CYAN}[0]${NC}  退出脚本"
    echo -e "${GREEN}============================================${NC}"
    echo -ne " 请输入数字选择 [0-5]: "
    read choice

    case $choice in
        1) install_anytls; read_return ;;
        2) show_info; read_return ;;
        3) change_port; read_return ;;
        4) restart_service && echo -e "${GREEN}✅ 服务已重启${NC}"; read_return ;;
        5) 
            echo -ne "${RED}确认卸载吗？(y/n): ${NC}"
            read confirm
            if [[ $confirm == [yY] ]]; then
                if command -v systemctl >/dev/null; then
                    # 加上 || true 防止服务未运行/不存在时导致脚本退出
                    systemctl stop ${SERVICE_NAME} 2>/dev/null || true
                    systemctl disable ${SERVICE_NAME} 2>/dev/null || true
                    rm -f /etc/systemd/system/${SERVICE_NAME}.service
                    systemctl daemon-reload
                else
                    rc-service ${SERVICE_NAME} stop 2>/dev/null || true
                    rc-update del ${SERVICE_NAME} 2>/dev/null || true
                    rm -f /etc/init.d/${SERVICE_NAME}
                fi
                rm -rf $WORK_DIR
                echo -e "${GREEN}✅ AnyTLS 已完全卸载${NC}"
            fi
            read_return
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 无效选择！${NC}"; sleep 1 ;;
    esac
done
