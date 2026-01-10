#!/bin/bash

# =================配置区域=================
ET_VERSION="v2.4.5"
ET_DIR="/opt/easytier"
SYSTEMD_DIR="/etc/systemd/system"
DEFAULT_NET_NAME="default_net"
DEFAULT_SECRET="123456"
GLOBAL_BIN_NAME="et-helper"
# 脚本托管地址（可替换为你的实际托管地址，用于一键运行和全局安装）
SCRIPT_RAW_URL="https://raw.githubusercontent.com/My-Search/easytier-helper/refs/heads/master/easytier-helper.sh"
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
    local tmp_dir="/tmp/et_install_temp"
    mkdir -p "$tmp_dir"
    
    if ! wget -q --show-progress -O "$tmp_dir/et.zip" "https://github.com/EasyTier/EasyTier/releases/download/${ET_VERSION}/easytier-linux-x86_64-${ET_VERSION}.zip"; then
        echo -e "${RED}下载 EasyTier 核心失败，请检查网络或版本号${NC}"
        rm -rf "$tmp_dir"
        exit 1
    fi
    
    unzip -q "$tmp_dir/et.zip" -d "$tmp_dir"
    mkdir -p "$ET_DIR"
    find "$tmp_dir" -name "easytier-core" -type f -exec mv {} "$ET_DIR/" \;
    chmod +x "$ET_DIR/easytier-core"
    rm -rf "$tmp_dir"
    echo -e "${GREEN}EasyTier 核心安装完成${NC}"
}

# 全局安装逻辑（支持管道模式运行时的自安装，完善一键下载逻辑）
install_self_global() {
    local target_path="/usr/local/bin/${GLOBAL_BIN_NAME}"
    echo -e "${YELLOW}正在安装全局命令 ${target_path}...${NC}"

    # 如果是从物理文件运行，直接复制
    if [ -f "$0" ] && [ "$0" != "bash" ] && [ "$0" != "/bin/bash" ]; then
        cp "$0" "$target_path"
    else
        # 管道模式下，直接从官方托管地址下载脚本（解决原脚本内容写入失败问题）
        if ! wget -q --show-progress -O "$target_path" "$SCRIPT_RAW_URL"; then
            echo -e "${RED}管道模式下下载全局脚本失败，请检查网络或脚本托管地址${NC}"
            return 1
        fi
    fi

    chmod +x "$target_path"
    if [ -x "$target_path" ]; then
        echo -e "${GREEN}全局命令安装成功！以后可以直接输入 ${BLUE}${GLOBAL_BIN_NAME}${NC} 运行。${NC}"
    else
        echo -e "${RED}全局命令安装失败，文件无法执行${NC}"
        rm -f "$target_path"
        return 1
    fi
}

# 全局卸载逻辑（对应 UI 中的「卸载」选项）
uninstall_self_global() {
    local target_path="/usr/local/bin/${GLOBAL_BIN_NAME}"
    if [ ! -f "$target_path" ]; then
        echo -e "${YELLOW}全局命令 ${GLOBAL_BIN_NAME} 未安装，无需卸载${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}正在卸载全局命令 ${target_path}...${NC}"
    rm -f "$target_path"
    
    if [ ! -f "$target_path" ]; then
        echo -e "${GREEN}全局命令 ${GLOBAL_BIN_NAME} 卸载成功${NC}"
    else
        echo -e "${RED}全局命令 ${GLOBAL_BIN_NAME} 卸载失败，请手动删除 ${target_path}${NC}"
        return 1
    fi
}

# 删除已配置的网络（新增核心函数）
delete_network() {
    # 先列出当前已配置的网络，方便用户选择
    list_networks
    
    read -p "请输入要删除的网络名称: " d_name
    # 校验网络名称非空
    if [ -z "$d_name" ]; then
        echo -e "${RED}删除失败：网络名称不能为空${NC}"
        return 1
    fi
    
    local service_name="easytier-${d_name}.service"
    local service_path="${SYSTEMD_DIR}/${service_name}"
    
    # 校验网络是否存在
    if [ ! -f "$service_path" ]; then
        echo -e "${RED}删除失败：网络 [${d_name}] 不存在${NC}"
        return 1
    fi
    
    # 停止并禁用对应服务
    echo -e "${YELLOW}正在删除网络 [${d_name}]...${NC}"
    systemctl disable --now "$service_name" 2>/dev/null
    
    # 删除服务配置文件
    rm -f "$service_path"
    
    # 刷新 systemd 配置
    systemctl daemon-reload
    
    # 验证删除结果
    if [ ! -f "$service_path" ]; then
        echo -e "${GREEN}网络 [${d_name}] 已成功删除${NC}"
    else
        echo -e "${RED}网络 [${d_name}] 删除失败，请手动删除 ${service_path}${NC}"
        return 1
    fi
}

# 获取随机端口
get_random_port() {
    echo $(( 11011 + RANDOM % 1000 ))
}

# 创建 Systemd 服务
create_service_file() {
    local net_name=$1
    local cmd_args=$2
    local service_name="easytier-${net_name}.service"
    local service_path="${SYSTEMD_DIR}/${service_name}"

    # 验证参数非空
    if [ -z "$net_name" ] || [ -z "$cmd_args" ]; then
        echo -e "${RED}创建服务失败：网络名称或命令参数不能为空${NC}"
        return 1
    fi

    # 停止现有服务（如果存在）
    if systemctl is-active --quiet "$service_name"; then
        systemctl stop "$service_name"
    fi

    cat <<EOF > "$service_path"
[Unit]
Description=EasyTier Network: ${net_name}
After=network.target network-online.target
Documentation=$SCRIPT_RAW_URL
[Service]
Type=simple
ExecStart=$ET_DIR/easytier-core $cmd_args
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535
WorkingDirectory=$ET_DIR
[Install]
WantedBy=multi-user.target
EOF

    # 重新加载配置并启动服务
    systemctl daemon-reload
    if systemctl enable "$service_name" --now; then
        echo -e "${GREEN}网络 [${net_name}] 服务已部署并启动${NC}"
    else
        echo -e "${RED}网络 [${net_name}] 服务启动失败，请检查 systemd 配置${NC}"
        rm -f "$service_path"
        systemctl daemon-reload
        return 1
    fi
}

# 列出网络（修复状态显示unknown问题）
list_networks() {
    echo -e "\n${BLUE}=== 当前已配置的 EasyTier 网络 ===${NC}"
    local services=$(ls ${SYSTEMD_DIR}/easytier-*.service 2>/dev/null)
    [ -z "$services" ] && echo -e "${YELLOW}暂无已配置的 EasyTier 网络${NC}" && return
    
    for svc in $services; do
        # 校验服务文件是否有效存在
        if [ ! -f "$svc" ]; then
            continue
        fi
        
        s_name=$(basename "$svc" .service)
        net_name=${s_name#easytier-}
        
        # 优化状态获取：静默执行，重定向所有错误输出，确保返回值准确
        if systemctl is-unit-file --quiet "$s_name" >/dev/null 2>&1; then
            # 服务已加载，获取真实活动状态
            status=$(systemctl is-active "$s_name" 2>/dev/null)
            # 补充状态说明，区分正常停止和异常
            if [ "$status" = "inactive" ]; then
                status="${status}（已停止）"
            elif [ "$status" = "active" ]; then
                status="${status}（运行中）"
            fi
        else
            # 服务未加载，标记为无效
            status="invalid（服务未加载）"
        fi
        
        # 优化虚拟IP获取，提高容错性
        ip=$(grep -oP '\-i \K[0-9\.]+' "$svc" 2>/dev/null || echo "未配置")
        echo -e "名称: ${YELLOW}${net_name}${NC} | 状态: ${GREEN}${status}${NC} | 虚拟IP: $ip"
    done
}

# 核心逻辑：创建/加入网络（修复一键加入命令）
run_add_logic() {
    local p_conn_ip=$1
    local p_my_ip=$2
    local p_net_name=$3
    local p_secret=$4

    # 填充默认值
    p_net_name=${p_net_name:-$DEFAULT_NET_NAME}
    p_secret=${p_secret:-$DEFAULT_SECRET}
    local local_port=$(get_random_port)
    local listener_arg="--listeners tcp://0.0.0.0:${local_port} udp://0.0.0.0:${local_port}"

    if [ -z "$p_conn_ip" ]; then
        # Host Mode：创建新网络
        p_my_ip=${p_my_ip:-"192.168.100.1"}
        # 验证虚拟IP格式（简单校验）
        if ! [[ "$p_my_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo -e "${RED}虚拟IP格式错误，请输入合法的IPv4地址${NC}"
            exit 1
        fi
        CMD_ARGS="-i ${p_my_ip} --network-name ${p_net_name} --network-secret ${p_secret} ${listener_arg}"
        create_service_file "$p_net_name" "$CMD_ARGS"
        
        # 优化公网IP获取：增加多个备用地址，提高成功率
        PUBLIC_IP=$(curl -s4 ifconfig.me 2>/dev/null || \
                    curl -s4 icanhazip.com 2>/dev/null || \
                    curl -s4 ipinfo.io/ip 2>/dev/null || \
                    echo "请替换为你的服务器公网IP")
        
        # 修复一键加入命令：统一脚本文件名，确保与实际脚本一致
        JOIN_CMD="curl -sSL ${SCRIPT_RAW_URL} -o /tmp/easytier-helper.sh && chmod +x /tmp/easytier-helper.sh && bash /tmp/easytier-helper.sh conn-ip=${PUBLIC_IP}:${local_port} my-ip=192.168.100.2 net-name=${p_net_name} secret=${p_secret}"
        
        echo -e "\n${GREEN}========== 网络创建成功 ==========${NC}"
        echo -e "网络名称：${YELLOW}${p_net_name}${NC}"
        echo -e "虚拟IP：${YELLOW}${p_my_ip}${NC}"
        echo -e "监听端口：${YELLOW}${local_port}（TCP/UDP）${NC}"
        echo -e "网络密钥：${YELLOW}${p_secret}${NC}"
        echo -e "\n${BLUE}其他节点一键加入命令（直接复制运行）：${NC}"
        echo -e "${YELLOW}${JOIN_CMD}${NC}"
    else
        # Client Mode：加入现有网络
        PEER_URL="tcp://${p_conn_ip}"
        [[ "$p_conn_ip" != *":"* ]] && PEER_URL="${PEER_URL}:11010"
        # 验证虚拟IP格式
        if [ -z "$p_my_ip" ] || ! [[ "$p_my_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo -e "${RED}请输入合法的虚拟IPv4地址${NC}"
            exit 1
        fi
        CMD_ARGS="-p ${PEER_URL} -i ${p_my_ip} --network-name ${p_net_name} --network-secret ${p_secret} ${listener_arg}"
        create_service_file "$p_net_name" "$CMD_ARGS"
        
        echo -e "\n${GREEN}========== 加入网络成功 ==========${NC}"
        echo -e "网络名称：${YELLOW}${p_net_name}${NC}"
        echo -e "虚拟IP：${YELLOW}${p_my_ip}${NC}"
        echo -e "连接节点：${YELLOW}${p_conn_ip}${NC}"
    fi
}

# ================= 入口逻辑 =================

# 先安装 EasyTier 核心
install_easytier

# 解析命令行参数
HAS_ARGS=false
PARAM_CONN_IP=""
PARAM_MY_IP=""
PARAM_NET_NAME=""
PARAM_SECRET=""

for arg in "$@"; do
  HAS_ARGS=true
  case $arg in
    conn-ip=*) PARAM_CONN_IP="${arg#*=}" ;;
    my-ip=*)    PARAM_MY_IP="${arg#*=}" ;;
    net-name=*) PARAM_NET_NAME="${arg#*=}" ;;
    secret=*)   PARAM_SECRET="${arg#*=}" ;;
    install)    install_self_global; exit 0 ;;
    uninstall)  uninstall_self_global; exit 0 ;;
    list)       list_networks; exit 0 ;;
    delete)     delete_network; exit 0 ;; # 新增命令行参数支持
    *)          echo -e "${YELLOW}未知参数：${arg}，忽略执行${NC}" ;;
  esac
done

# 带参数直接执行（一键加入网络）
if [ "$HAS_ARGS" = true ]; then
    run_add_logic "$PARAM_CONN_IP" "$PARAM_MY_IP" "$PARAM_NET_NAME" "$PARAM_SECRET"
else
    # 无参数进入【新UI布局】交互菜单（补充删除网络选项）
    while true; do
        echo -e "\n${BLUE}=== EasyTier 网络管理工具 ===${NC}"
        # 核心功能区（补充删除网络）
        echo "1. 创建网络"
        echo "2. 加入网络"
        echo "3. 查询已配置的网络"
        echo "4. 删除已配置的网络" # 新增UI选项
        # 第一根彩色分隔线（------------）
        echo -e "${BLUE}------------${NC}"
        # 辅助功能区
        echo "5. 安装为全局命令"
        echo "6. 卸载" # 序号顺延
        # 第二根彩色分隔线（--------------）
        echo -e "${BLUE}--------------${NC}"
        # 退出选项
        echo "0. 退出程序"
        
        read -p "请输入你的选择 [0-6]: " choice
        case $choice in
            1)  # 创建网络
                read -p "请输入网络名称 [默认: $DEFAULT_NET_NAME]: " t_name
                read -p "请输入网络密钥 [默认: $DEFAULT_SECRET]: " t_secret
                read -p "请输入主节点虚拟IP [默认: 192.168.100.1]: " t_my
                run_add_logic "" "$t_my" "$t_name" "$t_secret"
                ;;
            2)  # 加入网络
                read -p "请输入主节点连接地址（格式：IP:端口）: " t_conn
                read -p "请输入网络名称 [默认: $DEFAULT_NET_NAME]: " t_name
                read -p "请输入本节点虚拟IP: " t_my
                read -p "请输入网络密钥 [默认: $DEFAULT_SECRET]: " t_secret
                run_add_logic "$t_conn" "$t_my" "$t_name" "$t_secret"
                ;;
            3)  # 查询已配置的网络
                list_networks
                ;;
            4)  # 删除已配置的网络（新增菜单映射）
                delete_network
                ;;
            5)  # 安装为全局命令（序号顺延）
                install_self_global
                ;;
            6)  # 卸载（全局命令，序号顺延）
                uninstall_self_global
                ;;
            0)  # 退出程序
                echo -e "${BLUE}感谢使用 EasyTier 网络管理脚本，再见！${NC}"
                exit 0 
                ;;
            *)  # 无效选择
                echo -e "${RED}无效选择，请输入 0-6 之间的数字${NC}" ;;
        esac
    done
fi