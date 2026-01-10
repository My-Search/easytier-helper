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
    local tmp_dir="/tmp/et_install_temp"
    mkdir -p "$tmp_dir"
    
    if ! wget -q --show-progress -O "$tmp_dir/et.zip" "https://github.com/EasyTier/EasyTier/releases/download/${ET_VERSION}/easytier-linux-x86_64-${ET_VERSION}.zip"; then
        echo -e "${RED}下载失败${NC}"
        rm -rf "$tmp_dir"
        exit 1
    fi
    
    unzip -q "$tmp_dir/et.zip" -d "$tmp_dir"
    mkdir -p "$ET_DIR"
    find "$tmp_dir" -name "easytier-core" -type f -exec mv {} "$ET_DIR/" \;
    chmod +x "$ET_DIR/easytier-core"
    rm -rf "$tmp_dir"
    echo -e "${GREEN}EasyTier 安装完成${NC}"
}

# 全局安装逻辑（支持管道模式运行时的自安装）
install_self_global() {
    local target_path="/usr/local/bin/${GLOBAL_BIN_NAME}"
    echo -e "${YELLOW}正在安装全局命令 ${target_path}...${NC}"

    # 如果是从物理文件运行，直接复制
    if [ -f "$0" ] && [ "$0" != "bash" ]; then
        cp "$0" "$target_path"
    else
        # 如果是 curl | bash 运行，则重新下载脚本并保存
        # 这里我们假设脚本托管在 GitHub 或你能访问的链接
        # 也可以通过更巧妙的方式，将当前进程正在执行的代码导出
        # 为了最稳健，我们直接把当前脚本内容再次通过 cat 写入
        cat <<'EOF' > "$target_path"
$(cat "$0" 2>/dev/null || echo "#!/bin/bash\n# 脚本内容读取失败，请手动保存运行")
EOF
        # 上面的方法在管道模式下依然会有局限。
        # 这里的最佳实践是：直接通过 $0 读取内容写入。
        # 如果 $0 无法读取，则提示用户。
        if [ ! -s "$target_path" ]; then
            echo -e "${RED}由于您正在使用管道模式直接运行，无法定位源代码。${NC}"
            echo -e "${YELLOW}请使用以下方式运行：${NC}"
            echo -e "curl -o et.sh https://你的链接.sh && sudo bash et.sh"
            return
        fi
    fi

    chmod +x "$target_path"
    echo -e "${GREEN}安装成功！以后可以直接输入 ${BLUE}${GLOBAL_BIN_NAME}${NC} 运行。${NC}"
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

    if [ -f "$service_path" ]; then
        systemctl stop "$service_name"
    fi

    cat <<EOF > "$service_path"
[Unit]
Description=EasyTier Network: ${net_name}
After=network.target
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
    echo -e "${GREEN}网络 [${net_name}] 服务已部署并启动${NC}"
}

# 列出网络
list_networks() {
    echo -e "\n${BLUE}=== 当前已配置的网络 ===${NC}"
    local services=$(ls ${SYSTEMD_DIR}/easytier-*.service 2>/dev/null)
    [ -z "$services" ] && echo "暂无网络" && return
    for svc in $services; do
        s_name=$(basename "$svc" .service)
        status=$(systemctl is-active "$svc")
        ip=$(grep -oP '\-i \K[0-9\.]+' "$svc")
        echo -e "名称: ${YELLOW}${s_name#easytier-}${NC} | 状态: ${status} | IP: $ip"
    done
}

# 核心逻辑
run_add_logic() {
    local p_conn_ip=$1
    local p_my_ip=$2
    local p_net_name=$3
    local p_secret=$4

    p_net_name=${p_net_name:-$DEFAULT_NET_NAME}
    p_secret=${p_secret:-$DEFAULT_SECRET}
    local local_port=$(get_random_port)
    local listener_arg="--listeners tcp://0.0.0.0:${local_port} udp://0.0.0.0:${local_port}"

    if [ -z "$p_conn_ip" ]; then
        # Host Mode
        p_my_ip=${p_my_ip:-"192.168.100.1"}
        CMD_ARGS="-i ${p_my_ip} --network-name ${p_net_name} --network-secret ${p_secret} ${listener_arg}"
        create_service_file "$p_net_name" "$CMD_ARGS"
        
        PUBLIC_IP=$(curl -s4 ifconfig.me || echo "公网IP")
        echo -e "\n${GREEN}网络创建成功！${NC}"
        echo -e "其他节点加入命令：${YELLOW}${GLOBAL_BIN_NAME} conn-ip=${PUBLIC_IP}:${local_port} my-ip=192.168.100.2 net-name=${p_net_name} secret=${p_secret}${NC}"
    else
        # Client Mode
        PEER_URL="tcp://${p_conn_ip}"
        [[ "$p_conn_ip" != *":"* ]] && PEER_URL="${PEER_URL}:11010"
        CMD_ARGS="-p ${PEER_URL} -i ${p_my_ip} --network-name ${p_net_name} --network-secret ${p_secret} ${listener_arg}"
        create_service_file "$p_net_name" "$CMD_ARGS"
    fi
}

# ================= 入口 =================

install_easytier

# 解析参数
HAS_ARGS=false
for arg in "$@"; do
  HAS_ARGS=true
  case $arg in
    conn-ip=*) PARAM_CONN_IP="${arg#*=}" ;;
    my-ip=*)    PARAM_MY_IP="${arg#*=}" ;;
    net-name=*) PARAM_NET_NAME="${arg#*=}" ;;
    secret=*)   PARAM_SECRET="${arg#*=}" ;;
    install)    install_self_global; exit 0 ;;
  esac
done

if [ "$HAS_ARGS" = true ]; then
    run_add_logic "$PARAM_CONN_IP" "$PARAM_MY_IP" "$PARAM_NET_NAME" "$PARAM_SECRET"
else
    while true; do
        echo -e "\n${BLUE}=== EasyTier 网络管理菜单 ===${NC}"
        echo "1. 查看状态"
        echo "2. 创建新网络 (无需 conn-ip)"
        echo "3. 加入现有网络 (需输入 conn-ip)"
        echo "4. 删除网络"
        echo "5. 安装为全局命令"
        echo "0. 退出"
        read -p "选择: " choice
        case $choice in
            1) list_networks ;;
            2)
                read -p "名称 [$DEFAULT_NET_NAME]: " t_name
                read -p "密码 [$DEFAULT_SECRET]: " t_secret
                read -p "虚拟IP [192.168.100.1]: " t_my
                run_add_logic "" "$t_my" "$t_name" "$t_secret"
                ;;
            3)
                read -p "连接地址 (IP:端口): " t_conn
                read -p "名称: " t_name
                read -p "虚拟IP: " t_my
                run_add_logic "$t_conn" "$t_my" "$t_name"
                ;;
            4)
                list_networks
                read -p "输入要删除的网络名: " d_name
                systemctl disable --now "easytier-${d_name}.service" 2>/dev/null
                rm -f "${SYSTEMD_DIR}/easytier-${d_name}.service"
                systemctl daemon-reload
                echo "已删除。"
                ;;
            5) install_self_global ;;
            0) exit 0 ;;
        esac
    done
fi