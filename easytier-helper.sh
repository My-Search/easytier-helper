#!/bin/bash
# EasyTier 管理脚本 (优化版 v2.5)
# 更新日志：
# - Fix: 修复生成的加入命令中 my-ip 硬编码为 192.168.100.2 的问题
# - Feat: 根据主节点 IP 自动推算客户端建议 IP
# - Feat: 优化参数解析与交互流程
#
# 使用方法示例：
#   bash easytier-helper.sh                # 交互模式
#   bash easytier-helper.sh install        # 安装为全局命令
#   bash easytier-helper.sh list           # 列出已配置网络
#   bash easytier-helper.sh delete         # 交互删除
#   bash easytier-helper.sh conn-ip=IP:PORT my-ip=10.0.0.2 net-name=vpn secret=123

set -euo pipefail

# =================配置区域=================
ET_VERSION="v2.4.5"
ET_DIR="/opt/easytier"
SYSTEMD_DIR="/etc/systemd/system"
DEFAULT_NET_NAME="default_net"
DEFAULT_SECRET="123456"
DEFAULT_HOST_IP="192.168.100.1"
GLOBAL_BIN_NAME="easytier-helper"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/My-Search/easytier-helper/refs/heads/master/easytier-helper.sh"
# =========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 sudo 或 root 运行此脚本${NC}"
  exit 1
fi

# 检查必要命令
_required_cmds=(wget unzip systemctl curl grep awk sed)
for _c in "${_required_cmds[@]}"; do
  if ! command -v "${_c}" >/dev/null 2>&1; then
    echo -e "${YELLOW}警告：缺少命令 ${_c}，部分功能可能受限。建议先安装：apt install ${_c} 或 yum install ${_c}${NC}"
  fi
done

# ================= 核心函数 =================

# 简单的 IP 自增逻辑 (192.168.100.1 -> 192.168.100.2)
get_next_ip() {
    local ip=$1
    echo "$ip" | awk -F. '{$NF = $NF + 1;} 1' OFS=.
}

install_easytier() {
  if [ -x "${ET_DIR}/easytier-core" ]; then
    return 0
  fi
  echo -e "${YELLOW}正在安装 EasyTier ${ET_VERSION}...${NC}"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN

  local zip_url="https://github.com/EasyTier/EasyTier/releases/download/${ET_VERSION}/easytier-linux-x86_64-${ET_VERSION}.zip"
  if ! wget -q --show-progress -O "${tmp_dir}/et.zip" "${zip_url}"; then
    echo -e "${RED}下载 EasyTier 失败，请检查网络。URL: ${zip_url}${NC}"
    return 1
  fi

  if ! unzip -q "${tmp_dir}/et.zip" -d "${tmp_dir}"; then
    echo -e "${RED}解压失败，请确认 unzip 已安装${NC}"
    return 1
  fi

  mkdir -p "${ET_DIR}"
  find "${tmp_dir}" -type f -name "easytier-core" -exec mv {} "${ET_DIR}/" \; || true
  
  if [ ! -f "${ET_DIR}/easytier-core" ]; then
    echo -e "${RED}错误：未找到 easytier-core 文件${NC}"
    return 1
  fi
  chmod +x "${ET_DIR}/easytier-core"
  echo -e "${GREEN}EasyTier 安装完成。${NC}"
}

install_self_global() {
  local target_path="/usr/local/bin/${GLOBAL_BIN_NAME}"
  echo -e "${YELLOW}正在安装全局命令 ${target_path}...${NC}"
  
  # 优先复制当前脚本
  if [ -f "$0" ] && [ -r "$0" ]; then
    cp -f "$0" "${target_path}"
  else
    if ! wget -q --show-progress -O "${target_path}" "${SCRIPT_RAW_URL}"; then
      echo -e "${RED}下载脚本失败${NC}"
      return 1
    fi
  fi
  
  chmod +x "${target_path}"
  echo -e "${GREEN}安装成功！可直接运行：${BLUE}${GLOBAL_BIN_NAME}${NC}"
}

uninstall_self_global() {
  rm -f "/usr/local/bin/${GLOBAL_BIN_NAME}"
  echo -e "${GREEN}已移除全局命令${NC}"
}

get_random_port() {
  shuf -i 11011-11999 -n 1 2>/dev/null || echo $((11011 + RANDOM % 989))
}

create_service_file() {
  local net_name="$1"
  local cmd_args="$2"
  local service_name="easytier-${net_name}.service"
  local service_path="${SYSTEMD_DIR}/${service_name}"

  [ -z "${net_name}" ] && return 1

  # 清理旧服务
  if systemctl list-unit-files | grep -q "^${service_name}"; then
    systemctl stop "${service_name}" 2>/dev/null || true
    systemctl disable "${service_name}" 2>/dev/null || true
  fi

  cat > "${service_path}" <<EOF
[Unit]
Description=EasyTier Network: ${net_name}
After=network.target network-online.target

[Service]
Type=simple
ExecStart=${ET_DIR}/easytier-core ${cmd_args}
Restart=always
RestartSec=5s
LimitNOFILE=65535
WorkingDirectory=${ET_DIR}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  if systemctl enable --now "${service_name}"; then
    echo -e "${GREEN}网络服务 [${net_name}] 已启动${NC}"
    return 0
  else
    echo -e "${RED}服务启动失败，请检查: systemctl status ${service_name}${NC}"
    rm -f "${service_path}"
    return 1
  fi
}

_extract_ip_from_service() {
  local svc_file="$1"
  local ip="未配置"
  if [ -f "${svc_file}" ]; then
    # 优先匹配 -i 参数
    ip=$(grep -oP '(?<=\s-i\s)[0-9]{1,3}(\.[0-9]{1,3}){3}' "${svc_file}" 2>/dev/null || true)
    # 其次匹配 listeners 中的 tcp://IP
    if [ -z "${ip}" ]; then
        ip=$(grep -oP '(?<=tcp://)[0-9\.]+(?=:)' "${svc_file}" | grep -v '0.0.0.0' | head -n 1 || true)
    fi
  fi
  echo "${ip:-未知}"
}

list_networks() {
  echo -e "\n${BLUE}=== 已配置的网络 ===${NC}"
  local services
  services=$(ls "${SYSTEMD_DIR}"/easytier-*.service 2>/dev/null || true)
  
  if [ -z "${services}" ]; then
    echo -e "${YELLOW}暂无网络配置${NC}"
    return 0
  fi

  while IFS= read -r svc; do
    [ ! -f "${svc}" ] && continue
    s_name=$(basename "${svc}")
    net_name="${s_name#easytier-}"
    net_name="${net_name%.service}"

    if systemctl is-active --quiet "${s_name}"; then
        status="${GREEN}运行中${NC}"
    else
        status="${RED}已停止${NC}"
    fi

    ip=$(_extract_ip_from_service "${svc}")
    echo -e "网络: ${YELLOW}${net_name}${NC} | 状态: ${status} | 虚拟IP: ${BLUE}${ip}${NC}"
  done <<< "${services}"
}

delete_network_by_name() {
  local d_name="$1"
  local service_name="easytier-${d_name}.service"
  local service_path="${SYSTEMD_DIR}/${service_name}"

  if [ ! -f "${service_path}" ]; then
    echo -e "${RED}未找到网络: ${d_name}${NC}"
    return 1
  fi

  systemctl stop "${service_name}" 2>/dev/null || true
  systemctl disable "${service_name}" 2>/dev/null || true
  rm -f "${service_path}"
  systemctl daemon-reload
  echo -e "${GREEN}网络 [${d_name}] 已删除${NC}"
}

# 核心逻辑：添加/加入网络
run_add_logic() {
  local p_conn_ip="$1"  # 如果为空，则是 Host 模式
  local p_my_ip="$2"
  local p_net_name="${3:-$DEFAULT_NET_NAME}"
  local p_secret="${4:-$DEFAULT_SECRET}"

  local local_port
  local_port="$(get_random_port)"
  local listener_arg="--listeners tcp://0.0.0.0:${local_port} udp://0.0.0.0:${local_port}"

  # --- Host 模式 (创建网络) ---
  if [ -z "${p_conn_ip}" ]; then
    p_my_ip=${p_my_ip:-$DEFAULT_HOST_IP}
    
    # 校验 IPv4 格式
    if ! [[ "${p_my_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo -e "${RED}错误：虚拟 IP 格式不正确 (${p_my_ip})${NC}"
      return 1
    fi

    # 启动服务
    CMD_ARGS="-i ${p_my_ip} --network-name ${p_net_name} --network-secret ${p_secret} ${listener_arg}"
    create_service_file "${p_net_name}" "${CMD_ARGS}"

    # 获取公网 IP 用于生成命令
    echo -e "${YELLOW}正在获取公网 IP...${NC}"
    PUBLIC_IP="$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com 2>/dev/null || echo 'YOUR_PUBLIC_IP')"
    
    # 自动计算建议给客户端的 IP (主机 IP + 1)
    CLIENT_SUGGEST_IP=$(get_next_ip "${p_my_ip}")

    # 生成准确的加入命令
    JOIN_CMD="curl -sSL ${SCRIPT_RAW_URL} -o /tmp/et.sh && chmod +x /tmp/et.sh && bash /tmp/et.sh conn-ip=${PUBLIC_IP}:${local_port} my-ip=${CLIENT_SUGGEST_IP} net-name=${p_net_name} secret=${p_secret}"

    echo -e "\n${GREEN}========== 网络创建成功 ==========${NC}"
    echo -e "网络名称 : ${YELLOW}${p_net_name}${NC}"
    echo -e "本机 IP  : ${YELLOW}${p_my_ip}${NC}"
    echo -e "密钥     : ${YELLOW}${p_secret}${NC}"
    echo -e "监听端口 : ${YELLOW}${local_port}${NC}"
    echo -e "\n${BLUE}客户端一键加入命令 (已自动适配 IP):${NC}"
    echo -e "${YELLOW}${JOIN_CMD}${NC}"
    echo -e "${YELLOW}注意: 如果有多个客户端，请在每个客户端上修改 my-ip 为不同的地址 (如 ...${CLIENT_SUGGEST_IP%.*}.X)${NC}"

  # --- Client 模式 (加入网络) ---
  else
    # 格式化连接地址
    PEER_URL="${p_conn_ip}"
    if [[ "${PEER_URL}" != *:* ]]; then
        PEER_URL="tcp://${PEER_URL}:11010" # 默认端口补全
    elif [[ "${PEER_URL}" != tcp://* ]] && [[ "${PEER_URL}" != udp://* ]]; then
        PEER_URL="tcp://${PEER_URL}"
    fi

    if [ -z "${p_my_ip}" ]; then
      echo -e "${RED}错误：加入网络必须指定本机的虚拟 IP (my-ip)${NC}"
      return 1
    fi

    CMD_ARGS="-p ${PEER_URL} -i ${p_my_ip} --network-name ${p_net_name} --network-secret ${p_secret} ${listener_arg}"
    create_service_file "${p_net_name}" "${CMD_ARGS}"

    echo -e "\n${GREEN}========== 加入网络成功 ==========${NC}"
    echo -e "网络名称 : ${YELLOW}${p_net_name}${NC}"
    echo -e "本机 IP  : ${YELLOW}${p_my_ip}${NC}"
    echo -e "连接至   : ${YELLOW}${PEER_URL}${NC}"
  fi
}

# ================= 入口逻辑 =================
install_easytier || true

# 参数解析变量
P_CONN=""
P_MY=""
P_NAME=""
P_SEC=""
P_DEL=""
HAS_ARGS=false

# 增强的参数解析
for arg in "$@"; do
  if [[ "$arg" == *=* ]]; then
    HAS_ARGS=true
    key="${arg%%=*}"
    val="${arg#*=}"
    case "$key" in
      conn-ip)  P_CONN="$val" ;;
      my-ip)    P_MY="$val" ;;
      net-name) P_NAME="$val" ;;
      secret)   P_SEC="$val" ;;
      delete)   P_DEL="$val" ;;
    esac
  else
    case "$arg" in
      install)   install_self_global; exit 0 ;;
      uninstall) uninstall_self_global; exit 0 ;;
      list)      list_networks; exit 0 ;;
      delete)    
        list_networks
        read -rp "请输入要删除的网络名称: " d_n
        [ -n "$d_n" ] && delete_network_by_name "$d_n"
        exit 0 
        ;;
    esac
  fi
done

# 如果通过命令行传参删网络
if [ -n "${P_DEL}" ]; then
  delete_network_by_name "${P_DEL}"
  exit 0
fi

# 如果通过命令行传参配置网络
if [ "$HAS_ARGS" = true ]; then
  run_add_logic "${P_CONN}" "${P_MY}" "${P_NAME}" "${P_SEC}"
  exit $?
fi

# 交互式菜单
while true; do
  echo -e "\n${BLUE}=== EasyTier 网络管理工具 ===${NC}"
  echo "1. 创建网络 (我是主机)"
  echo "2. 加入网络 (我是客户端)"
  echo "3. 查看网络状态"
  echo "4. 删除网络"
  echo "5. 安装到系统命令"
  echo "0. 退出"
  
  read -rp "请选择 [0-5]: " choice
  case "${choice}" in
    1)
      read -rp "网络名称 [${DEFAULT_NET_NAME}]: " t_n; t_n=${t_n:-$DEFAULT_NET_NAME}
      read -rp "网络密钥 [${DEFAULT_SECRET}]: " t_s; t_s=${t_s:-$DEFAULT_SECRET}
      read -rp "本机虚拟IP [${DEFAULT_HOST_IP}]: " t_ip; t_ip=${t_ip:-$DEFAULT_HOST_IP}
      run_add_logic "" "${t_ip}" "${t_n}" "${t_s}"
      ;;
    2)
      read -rp "主机连接地址 (IP:端口): " t_c
      read -rp "网络名称 [${DEFAULT_NET_NAME}]: " t_n; t_n=${t_n:-$DEFAULT_NET_NAME}
      read -rp "网络密钥 [${DEFAULT_SECRET}]: " t_s; t_s=${t_s:-$DEFAULT_SECRET}
      read -rp "本机虚拟IP (例 192.168.100.2): " t_ip
      run_add_logic "${t_c}" "${t_ip}" "${t_n}" "${t_s}"
      ;;
    3) list_networks ;;
    4) 
       list_networks
       read -rp "输入要删除的网络名称: " d_n
       [ -n "$d_n" ] && delete_network_by_name "$d_n"
       ;;
    5) install_self_global ;;
    0) exit 0 ;;
    *) echo -e "${RED}输入无效${NC}" ;;
  esac
done
