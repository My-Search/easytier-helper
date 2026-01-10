#!/bin/bash

# =================配置区域=================
ET_VERSION="v2.4.5"
ET_DIR="/opt/easytier"
SYSTEMD_DIR="/etc/systemd/system"
DEFAULT_NET_NAME="default_net"
DEFAULT_SECRET="123456"
GLOBAL_BIN_NAME="et-helper"
# =========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 sudo 运行此脚本${NC}"
  exit 1
fi

# ================= 工具函数 =================

# 安装 EasyTier 核心
install_easytier() {
    if [ -f "$ET_DIR/easytier-core" ]; then
        return
    fi
    echo -e "${YELLOW}正在安装 EasyTier ${ET_VERSION}...${NC}"
    rm -rf easytier-linux-x86_64*
    wget -q --show-progress "https://github.com/EasyTier/EasyTier/releases/download/${ET_VERSION}/easytier-linux-x86_64-${ET_VERSION}.zip"
    if [ $? -ne 0 ]; then echo -e "${RED}下载失败${NC}"; exit 1; fi
    unzip -q "easytier-linux-x86_64-${ET_VERSION}.zip"
    mkdir -p "$ET_DIR"
    find . -maxdepth 2 -name "easytier-core" -exec mv {} "$ET_DIR/" \;
    chmod 777 -R "$ET_DIR"
    rm -rf easytier-linux-x86_64*
    echo -e "${GREEN}EasyTier 安装完成${NC}"
}

# 安装脚本自身到系统全局
install_self_global() {
    local target_path="/usr/local/bin/${GLOBAL_BIN_NAME}"
    echo -e "${YELLOW}正在将脚本安装到 ${target_path}...${NC}"
    
    # 复制当前脚本内容到目标位置
    cp "$0" "$target_path"
    chmod +x "$target_path"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}安装成功！${NC}"
        echo -e "以后可以在任何地方直接输入 ${BLUE}${GLOBAL_BIN_NAME}${NC} 来运行工具。"
    else
        echo -e "${RED}安装失败，请检查权限。${NC}"
    fi
}

# 获取随机端口
get_random_port() {
    echo $(( 11011 + RANDOM % 1000 ))
}

# 创建服务并启动
create_service_file() {
    local net_name=$1
    local cmd_args=$2
    local service_name="easytier-${net_name}.service"
    local service_path="${SYSTEMD_DIR}/${service_name}"

    if [ -f "$service_path" ]; then
        echo -e "${RED}警告: 网络 [${net_name}] 已存在，配置将被更新。${NC}"
        systemctl stop "$service_name"
    fi

    cat <<EOF > "$service_path"
[Unit]
Description=EasyTier Network: ${net_name}
After=network.target syslog.target
Wants=network.target

[Service]
Type=simple
ExecStart=$ET_DIR/easytier-core $cmd_args
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$service_name" --now
    echo -e "${GREEN}网络 [${net_name}] 已启动！${NC}"
}

# 显示所有已创建的网络
list_networks() {
    echo -e "${BLUE}=== 当前已配置的网络列表 ===${NC}"
    local services=$(ls ${SYSTEMD_DIR}/easytier-*.service 2>/dev/null)
    if [ -z "$services" ]; then
        echo "暂无网络。"
        return
    fi
    
    for svc in $services; do
        s_name=$(basename "$svc")
        net_real_name=${s_name#easytier-}
        net_real_name=${net_real_name%.service}
        
        status=$(systemctl is-active "$s_name")
        if [ "$status" == "active" ]; then
            status_color="${GREEN}运行中${NC}"
        else
            status_color="${RED}已停止${NC}"
        fi
        
        exec_line=$(grep "ExecStart" "$svc")
        ip=$(echo "$exec_line" | grep -oP '\-i \K[0-9\.]+')
        echo -e "网络: ${YELLOW}${net_real_name}${NC} | 状态: ${status_color} | IP: ${ip}"
    done
    echo "=============================="
}

# 删除网络
delete_network() {
    list_networks
    read -p "请输入要删除/停止的网络名称: " del_name
    if [ -z "$del_name" ]; then return; fi
    
    local svc="easytier-${del_name}.service"
    if [ -f "${SYSTEMD_DIR}/$svc" ]; then
        systemctl stop "$svc"
        systemctl disable "$svc"
        rm "${SYSTEMD_DIR}/$svc"
        systemctl daemon-reload
        echo -e "${GREEN}网络 [${del_name}] 已删除。${NC}"
    else
        echo -e "${RED}未找到该网络。${NC}"
    fi
}

# ================= 核心逻辑：添加/加入网络 =================
run_add_logic() {
    local p_conn_ip=$1
    local p_my_ip=$2
    local p_net_name=$3
    local p_secret=$4

    if [ -z "$p_net_name" ]; then
        read -p "设置网络名称 (默认: $DEFAULT_NET_NAME): " p_net_name
        p_net_name=${p_net_name:-$DEFAULT_NET_NAME}
    fi
    if [ -z "$p_secret" ]; then
        read -p "设置网络密码 (默认: $DEFAULT_SECRET): " p_secret
        p_secret=${p_secret:-$DEFAULT_SECRET}
    fi

    local local_port=$(get_random_port)
    local listener_arg="--listeners tcp://0.0.0.0:${local_port} udp://0.0.0.0:${local_port}"

    if [ -z "$p_conn_ip" ]; then
        # Host Mode
        echo -e "${BLUE}>>> 模式: 创建新网络 (Host)${NC}"
        p_my_ip=${p_my_ip:-"192.168.100.1"}
        
        CMD_ARGS="-i ${p_my_ip} --network-name ${p_net_name} --network-secret ${p_secret} ${listener_arg}"
        create_service_file "$p_net_name" "$CMD_ARGS"
        
        PUBLIC_IP=$(curl -s4 ifconfig.me)
        [ -z "$PUBLIC_IP" ] && PUBLIC_IP="<公网IP>"
        
        prefix=$(echo $p_my_ip | cut -d'.' -f1-3)
        suffix=$(echo $p_my_ip | cut -d'.' -f4)
        next_ip="${prefix}.$((suffix+1))"

        echo -e "\n${GREEN}网络 [${p_net_name}] 创建成功！${NC}"
        echo -e "加入命令: ${YELLOW}${GLOBAL_BIN_NAME} conn-ip=${PUBLIC_IP}:${local_port} my-ip=${next_ip} net-name=${p_net_name} secret=${p_secret}${NC}"

    else
        # Client Mode
        echo -e "${BLUE}>>> 模式: 加入网络 (Client)${NC}"
        if [[ "$p_conn_ip" != *":"* ]]; then
             PEER_URL="tcp://${p_conn_ip}:11010" 
             echo -e "${YELLOW}提示: conn-ip 未指定端口，默认尝试 11010${NC}"
        else
             if [[ "$p_conn_ip" != *"//"* ]]; then PEER_URL="tcp://${p_conn_ip}"; else PEER_URL="${p_conn_ip}"; fi
        fi

        if [ -z "$p_my_ip" ]; then
            read -p "请输入本机静态IP (如 192.168.100.2): " p_my_ip
        fi
        [ -z "$p_my_ip" ] && { echo "IP 不能为空"; exit 1; }

        CMD_ARGS="-p ${PEER_URL} -i ${p_my_ip} --network-name ${p_net_name} --network-secret ${p_secret} ${listener_arg}"
        create_service_file "$p_net_name" "$CMD_ARGS"
        echo -e "\n${GREEN}已加入网络 [${p_net_name}]${NC}"
    fi
}


# ================= 程序入口 =================

install_easytier

# 检查是否为安装命令
if [ "$1" == "install" ]; then
    install_self_global
    exit 0
fi

# 解析命令行参数
PARAM_CONN_IP=""
PARAM_MY_IP=""
PARAM_NET_NAME=""
PARAM_SECRET=""
HAS_ARGS=false

for arg in "$@"; do
  HAS_ARGS=true
  case $arg in
    conn-ip=*) PARAM_CONN_IP="${arg#*=}" ;;
    my-ip=*)    PARAM_MY_IP="${arg#*=}" ;;
    net-name=*) PARAM_NET_NAME="${arg#*=}" ;;
    secret=*)   PARAM_SECRET="${arg#*=}" ;;
  esac
done

if [ "$HAS_ARGS" = true ]; then
    run_add_logic "$PARAM_CONN_IP" "$PARAM_MY_IP" "$PARAM_NET_NAME" "$PARAM_SECRET"
else
    # 交互菜单
    while true; do
        echo -e "\n${BLUE}=== EasyTier 网络管理器 ===${NC}"
        echo "1. 查看已配置的网络"
        echo "2. 创建/加入 新网络"
        echo "3. 删除/停止 网络"
        echo "4. 安装脚本到系统全局命令 (et-helper)"
        echo "0. 退出"
        read -p "请选择 [0-4]: " choice
        
        case $choice in
            1) list_networks ;;
            2) 
                read -p "网络名称 (英文): " t_name
                read -p "网络密码: " t_secret
                read -p "连接IP (conn-ip, 为空则创建网络): " t_conn
                read -p "本机IP (my-ip): " t_my
                run_add_logic "$t_conn" "$t_my" "$t_name" "$t_secret"
                ;;
            3) delete_network ;;
            4) install_self_global ;;
            0) exit 0 ;;
            *) echo "无效选择" ;;
        esac
    done
fi