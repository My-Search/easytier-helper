#!/bin/bash
# EasyTier 管理脚本（已增强：支持删除已配置网络、可靠状态检查与更稳健的虚拟IP提取）
# 使用方法示例：
#   bash easytier-helper.sh                # 交互模式
#   bash easytier-helper.sh install        # 安装为全局命令
#   bash easytier-helper.sh uninstall      # 卸载全局命令
#   bash easytier-helper.sh list           # 列出已配置网络
#   bash easytier-helper.sh delete         # 交互删除
#   bash easytier-helper.sh delete=my_net  # 直接删除 my_net
#   bash easytier-helper.sh conn-ip=IP:PORT my-ip=192.168.100.2 net-name=foo secret=bar

set -euo pipefail

# =================配置区域=================
ET_VERSION="v2.4.5"
ET_DIR="/opt/easytier"
SYSTEMD_DIR="/etc/systemd/system"
DEFAULT_NET_NAME="default_net"
DEFAULT_SECRET="123456"
GLOBAL_BIN_NAME="easytier-helper"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/My-Search/easytier-helper/refs/heads/master/easytier-helper.sh"
# =========================================

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 必要命令检查
_required_cmds=(wget unzip systemctl curl grep awk sed)
for _c in "${_required_cmds[@]}"; do
  if ! command -v "${_c}" >/dev/null 2>&1; then
    echo -e "${YELLOW}警告：缺少命令 ${_c}，部分功能可能不可用。请安装它后重试。${NC}"
  fi
done

# 必须以 root 运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 sudo 或 root 运行此脚本${NC}"
  exit 1
fi

# ================= 工具函数 =================

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
    echo -e "${RED}下载 EasyTier 核心失败，请检查网络或版本号：${zip_url}${NC}"
    return 1
  fi

  if ! unzip -q "${tmp_dir}/et.zip" -d "${tmp_dir}"; then
    echo -e "${RED}解压失败，请确认 unzip 可用且压缩包完整${NC}"
    return 1
  fi

  mkdir -p "${ET_DIR}"
  find "${tmp_dir}" -type f -name "easytier-core" -exec mv {} "${ET_DIR}/" \; || true
  if [ ! -f "${ET_DIR}/easytier-core" ]; then
    echo -e "${RED}未在压缩包中找到 easytier-core 可执行文件${NC}"
    return 1
  fi
  chmod +x "${ET_DIR}/easytier-core"
  echo -e "${GREEN}EasyTier 核心安装完成：${ET_DIR}/easytier-core${NC}"
}

install_self_global() {
  local target_path="/usr/local/bin/${GLOBAL_BIN_NAME}"
  echo -e "${YELLOW}正在安装全局命令 ${target_path}...${NC}"

  if [ -f "$0" ] && [ -r "$0" ]; then
    cp -f "$0" "${target_path}"
  else
    if ! wget -q --show-progress -O "${target_path}" "${SCRIPT_RAW_URL}"; then
      echo -e "${RED}下载全局脚本失败：${SCRIPT_RAW_URL}${NC}"
      return 1
    fi
  fi

  chmod +x "${target_path}"
  if [ -x "${target_path}" ]; then
    echo -e "${GREEN}全局命令安装成功，可以直接运行：${BLUE}${GLOBAL_BIN_NAME}${NC}"
  else
    echo -e "${RED}全局命令安装失败，请检查权限${NC}"
    rm -f "${target_path}"
    return 1
  fi
}

uninstall_self_global() {
  local target_path="/usr/local/bin/${GLOBAL_BIN_NAME}"
  if [ ! -f "${target_path}" ]; then
    echo -e "${YELLOW}未检测到全局命令：${GLOBAL_BIN_NAME}${NC}"
    return 0
  fi
  rm -f "${target_path}"
  echo -e "${GREEN}已移除全局命令：${GLOBAL_BIN_NAME}${NC}"
}

get_random_port() {
  # 11011 - 11999 范围随机（简单实现）
  shuf -i 11011-11999 -n 1 2>/dev/null || echo $((11011 + RANDOM % 989))
}

create_service_file() {
  local net_name="$1"
  local cmd_args="$2"
  local service_name="easytier-${net_name}.service"
  local service_path="${SYSTEMD_DIR}/${service_name}"

  if [ -z "${net_name}" ] || [ -z "${cmd_args}" ]; then
    echo -e "${RED}创建服务失败：网络名称或命令参数不能为空${NC}"
    return 1
  fi

  # 停止并移除旧服务（若存在）
  if systemctl list-unit-files --type=service | grep -q "^${service_name}"; then
    systemctl stop "${service_name}" 2>/dev/null || true
    systemctl disable "${service_name}" 2>/dev/null || true
  fi

  cat > "${service_path}" <<EOF
[Unit]
Description=EasyTier Network: ${net_name}
After=network.target network-online.target
Documentation=${SCRIPT_RAW_URL}

[Service]
Type=simple
ExecStart=${ET_DIR}/easytier-core ${cmd_args}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535
WorkingDirectory=${ET_DIR}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  if systemctl enable --now "${service_name}"; then
    echo -e "${GREEN}网络 [${net_name}] 服务已部署并启动${NC}"
    return 0
  else
    echo -e "${RED}网络 [${net_name}] 服务启动失败，请检查 systemd 日志：journalctl -u ${service_name}${NC}"
    rm -f "${service_path}"
    systemctl daemon-reload
    return 1
  fi
}

# 更稳健的虚拟IP提取：支持 -i 和 --listeners 两种常见写法
_extract_ip_from_service() {
  local svc_file="$1"
  local ip="未配置"
  if [ -f "${svc_file}" ]; then
    # 先从 -i 后面提取 IPv4
    ip=$(grep -oP '(?<=\s-i\s)[0-9]{1,3}(\.[0-9]{1,3}){3}' "${svc_file}" 2>/dev/null || true)
    if [ -z "${ip}" ]; then
      # 尝试从 --listeners 中匹配 tcp://0.0.0.0:PORT 或 tcp://<ip>:PORT
      ip=$(grep -oP '(?<=--listeners\s)[^"]*' "${svc_file}" 2>/dev/null | grep -oP '(?<=tcp://)[0-9\.]+' 2>/dev/null || true)
    fi
    if [ -z "${ip}" ]; then
      ip="未配置"
    fi
  fi
  echo "${ip}"
}

list_networks() {
  echo -e "\n${BLUE}=== 当前已配置的 EasyTier 网络 ===${NC}"
  local services
  services=$(ls "${SYSTEMD_DIR}"/easytier-*.service 2>/dev/null || true)
  if [ -z "${services}" ]; then
    echo -e "${YELLOW}暂无已配置的 EasyTier 网络${NC}"
    return 0
  fi

  while IFS= read -r svc; do
    [ -z "${svc}" ] && continue
    [ ! -f "${svc}" ] && continue
    s_name=$(basename "${svc}")
    net_name="${s_name#easytier-}"
    net_name="${net_name%.service}"

    # 确认 systemd 是否识别到该单元
    if systemctl list-unit-files --type=service | grep -q "^${s_name}"; then
      active_status=$(systemctl is-active "${s_name}" 2>/dev/null || echo "unknown")
      enabled_status=$(systemctl is-enabled "${s_name}" 2>/dev/null || echo "disabled")
      case "${active_status}" in
        active) status="${active_status}（运行中）" ;;
        inactive) status="${active_status}（已停止）" ;;
        failed) status="${active_status}（失败）" ;;
        unknown) status="unknown（无法获取）" ;;
        *) status="${active_status}" ;;
      esac
    else
      status="invalid（服务未加载）"
      enabled_status="n/a"
    fi

    ip=$(_extract_ip_from_service "${svc}")

    # 输出（颜色管理）
    local status_color="${GREEN}"
    if [[ "${status}" == *"已停止"* ]] || [[ "${status}" == "invalid"* ]] || [[ "${status}" == *"失败"* ]] || [[ "${status}" == "unknown"* ]]; then
      status_color="${YELLOW}"
    fi
    echo -e "名称: ${YELLOW}${net_name}${NC} | 状态: ${status_color}${status}${NC} | 虚拟IP: ${BLUE}${ip}${NC} | 已启用: ${enabled_status}"
  done <<< "${services}"
}

delete_network_interactive() {
  list_networks
  read -p "请输入要删除的网络名称: " d_name
  if [ -z "${d_name}" ]; then
    echo -e "${RED}删除失败：网络名称不能为空${NC}"
    return 1
  fi
  delete_network_by_name "${d_name}"
}

delete_network_by_name() {
  local d_name="$1"
  local service_name="easytier-${d_name}.service"
  local service_path="${SYSTEMD_DIR}/${service_name}"

  if [ ! -f "${service_path}" ]; then
    echo -e "${RED}删除失败：网络 [${d_name}] 不存在（未找到 ${service_path}）${NC}"
    return 1
  fi

  echo -e "${YELLOW}正在停止并禁用服务：${service_name} ...${NC}"
  systemctl stop "${service_name}" 2>/dev/null || true
  systemctl disable "${service_name}" 2>/dev/null || true

  echo -e "${YELLOW}正在移除服务文件：${service_path}${NC}"
  rm -f "${service_path}"
  systemctl daemon-reload

  if [ ! -f "${service_path}" ]; then
    echo -e "${GREEN}网络 [${d_name}] 已成功删除${NC}"
    return 0
  else
    echo -e "${RED}网络 [${d_name}] 删除失败，请手动检查 ${service_path}${NC}"
    return 1
  fi
}

run_add_logic() {
  local p_conn_ip="$1"
  local p_my_ip="$2"
  local p_net_name="$3"
  local p_secret="$4"

  p_net_name=${p_net_name:-$DEFAULT_NET_NAME}
  p_secret=${p_secret:-$DEFAULT_SECRET}
  local local_port
  local_port="$(get_random_port)"
  local listener_arg="--listeners tcp://0.0.0.0:${local_port} udp://0.0.0.0:${local_port}"

  if [ -z "${p_conn_ip}" ]; then
    # Host mode
    p_my_ip=${p_my_ip:-"192.168.100.1"}
    if ! [[ "${p_my_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo -e "${RED}虚拟IP格式错误，请输入合法 IPv4 地址${NC}"
      return 1
    fi
    CMD_ARGS="-i ${p_my_ip} --network-name ${p_net_name} --network-secret ${p_secret} ${listener_arg}"
    create_service_file "${p_net_name}" "${CMD_ARGS}"

    # 获取公网 IP（多个备选）
    PUBLIC_IP="$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com 2>/dev/null || curl -s4 ipinfo.io/ip 2>/dev/null || true)"
    PUBLIC_IP="${PUBLIC_IP:-请替换为你的服务器公网IP}"

    JOIN_CMD="curl -sSL ${SCRIPT_RAW_URL} -o /tmp/easytier-helper.sh && chmod +x /tmp/easytier-helper.sh && bash /tmp/easytier-helper.sh conn-ip=${PUBLIC_IP}:${local_port} my-ip=192.168.100.2 net-name=${p_net_name} secret=${p_secret}"

    echo -e "\n${GREEN}========== 网络创建成功 ==========${NC}"
    echo -e "网络名称：${YELLOW}${p_net_name}${NC}"
    echo -e "虚拟IP：${YELLOW}${p_my_ip}${NC}"
    echo -e "监听端口：${YELLOW}${local_port}（TCP/UDP）${NC}"
    echo -e "网络密钥：${YELLOW}${p_secret}${NC}"
    echo -e "\n${BLUE}其他节点一键加入命令（复制运行）：${NC}"
    echo -e "${YELLOW}${JOIN_CMD}${NC}"
  else
    # Client mode (join)
    PEER_URL="${p_conn_ip}"
    if [[ "${PEER_URL}" != tcp://* ]] && [[ "${PEER_URL}" != udp://* ]]; then
      # allow input like 1.2.3.4:11011
      if [[ "${PEER_URL}" != *:* ]]; then
        PEER_URL="tcp://${PEER_URL}:11010"
      else
        PEER_URL="tcp://${PEER_URL}"
      fi
    fi

    if [ -z "${p_my_ip}" ] || ! [[ "${p_my_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo -e "${RED}加入失败：请输入合法的本节点虚拟 IPv4 地址（my-ip）${NC}"
      return 1
    fi

    CMD_ARGS="-p ${PEER_URL} -i ${p_my_ip} --network-name ${p_net_name} --network-secret ${p_secret} ${listener_arg}"
    create_service_file "${p_net_name}" "${CMD_ARGS}"

    echo -e "\n${GREEN}========== 加入网络成功 ==========${NC}"
    echo -e "网络名称：${YELLOW}${p_net_name}${NC}"
    echo -e "虚拟IP：${YELLOW}${p_my_ip}${NC}"
    echo -e "连接节点：${YELLOW}${p_conn_ip}${NC}"
  fi
}

# ================= 入口逻辑 =================
install_easytier || true

HAS_ARGS=false
PARAM_CONN_IP=""
PARAM_MY_IP=""
PARAM_NET_NAME=""
PARAM_SECRET=""
PARAM_DELETE_NAME=""

for arg in "$@"; do
  HAS_ARGS=true
  case "$arg" in
    conn-ip=*) PARAM_CONN_IP="${arg#*=}" ;;
    my-ip=*) PARAM_MY_IP="${arg#*=}" ;;
    net-name=*) PARAM_NET_NAME="${arg#*=}" ;;
    secret=*) PARAM_SECRET="${arg#*=}" ;;
    install) install_self_global; exit 0 ;;
    uninstall) uninstall_self_global; exit 0 ;;
    list) list_networks; exit 0 ;;
    delete=*) PARAM_DELETE_NAME="${arg#*=}" ;;
    delete) delete_network_interactive; exit 0 ;;
    *) echo -e "${YELLOW}忽略未知参数：${arg}${NC}" ;;
  esac
done

if [ -n "${PARAM_DELETE_NAME}" ]; then
  delete_network_by_name "${PARAM_DELETE_NAME}"
  exit $?
fi

if [ "${HAS_ARGS}" = true ]; then
  run_add_logic "${PARAM_CONN_IP}" "${PARAM_MY_IP}" "${PARAM_NET_NAME}" "${PARAM_SECRET}"
  exit $?
fi

# 交互菜单
while true; do
  echo -e "\n${BLUE}=== EasyTier 网络管理工具 ===${NC}"
  echo "1. 创建网络"
  echo "2. 加入网络"
  echo "3. 查询已配置的网络"
  echo "4. 删除已配置的网络"
  echo -e "${BLUE}------------${NC}"
  echo "5. 安装为全局命令"
  echo "6. 卸载全局命令"
  echo -e "${BLUE}--------------${NC}"
  echo "0. 退出程序"

  read -rp "请输入你的选择 [0-6]: " choice
  case "${choice}" in
    1)
      read -rp "请输入网络名称 [默认: ${DEFAULT_NET_NAME}]: " t_name
      read -rp "请输入网络密钥 [默认: ${DEFAULT_SECRET}]: " t_secret
      read -rp "请输入主节点虚拟IP [默认: 192.168.100.1]: " t_my
      t_name="${t_name:-$DEFAULT_NET_NAME}"
      t_secret="${t_secret:-$DEFAULT_SECRET}"
      t_my="${t_my:-192.168.100.1}"
      run_add_logic "" "${t_my}" "${t_name}" "${t_secret}"
      ;;
    2)
      read -rp "请输入主节点连接地址（格式：IP:端口）: " t_conn
      read -rp "请输入网络名称 [默认: ${DEFAULT_NET_NAME}]: " t_name
      read -rp "请输入本节点虚拟IP: " t_my
      read -rp "请输入网络密钥 [默认: ${DEFAULT_SECRET}]: " t_secret
      t_name="${t_name:-$DEFAULT_NET_NAME}"
      t_secret="${t_secret:-$DEFAULT_SECRET}"
      run_add_logic "${t_conn}" "${t_my}" "${t_name}" "${t_secret}"
      ;;
    3) list_networks ;;
    4) delete_network_interactive ;;
    5) install_self_global ;;
    6) uninstall_self_global ;;
    0) echo -e "${BLUE}感谢使用 EasyTier 网络管理脚本，再见！${NC}"; exit 0 ;;
    *) echo -e "${RED}无效选择，请输入 0-6 之间的数字${NC}" ;;
  esac
done
