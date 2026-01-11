#!/bin/bash
# EasyTier 管理脚本 (增强版 v2.6)
# 更新日志：
# - Feat: [关键] 新增 Watchdog 看门狗，通过 easytier-core route 检测进程响应，异常自动重启
# - Feat: [关键] 支持向现有网络追加 "子网代理" (暴露本机局域网)
# - Fix: 修复生成的加入命令中 my-ip 硬编码问题
# - Feat: 优化参数解析与交互流程
#
# 使用方法示例：
#   bash easytier-helper.sh                # 交互模式
#   bash easytier-helper.sh install        # 安装为全局命令
#   bash easytier-helper.sh add-proxy      # (命令行) 追加代理
#   bash easytier-helper.sh watchdog-check # (内部调用) 看门狗逻辑

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

# ================= 辅助工具函数 =================

get_next_ip() {
    local ip=$1
    echo "$ip" | awk -F. '{$NF = $NF + 1;} 1' OFS=.
}

get_random_port() {
  shuf -i 11011-11999 -n 1 2>/dev/null || echo $((11011 + RANDOM % 989))
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

_extract_ip_from_service() {
  local svc_file="$1"
  local ip="未配置"
  if [ -f "${svc_file}" ]; then
    ip=$(grep -oP '(?<=\s-i\s)[0-9]{1,3}(\.[0-9]{1,3}){3}' "${svc_file}" 2>/dev/null || true)
    if [ -z "${ip}" ]; then
        ip=$(grep -oP '(?<=tcp://)[0-9\.]+(?=:)' "${svc_file}" | grep -v '0.0.0.0' | head -n 1 || true)
    fi
  fi
  echo "${ip:-未知}"
}

# ================= Watchdog 逻辑 (核心新增) =================

# 看门狗检测函数：被 Timer 定时调用
watchdog_check() {
  local net_name="$1"
  local service_name="easytier-${net_name}.service"

  # 1. 如果服务本身应该是停止状态，则不干预
  if ! systemctl is-enabled "${service_name}" >/dev/null 2>&1; then
    return 0
  fi

  # 2. 检测核心进程响应能力
  # 使用 easytier-core route 命令尝试连接守护进程。如果进程僵死，该命令通常会超时或报错。
  # 注意：这里假设服务正在运行，如果 systemctl 状态是 fail，直接重启。
  
  if systemctl is-active "${service_name}" >/dev/null 2>&1; then
     # 服务显示运行中，进行应用层检测
     # 这里利用 easytier-core 的默认行为，它会尝试连接本地实例
     if ! timeout 5s "${ET_DIR}/easytier-core" route >/dev/null 2>&1; then
        echo "$(date): Watchdog 检测到 [${net_name}] 无响应，正在重启..." >> "${ET_DIR}/watchdog.log"
        systemctl restart "${service_name}"
     fi
  else
     # 服务未运行，尝试拉起
     echo "$(date): Watchdog 检测到 [${net_name}] 已停止，正在拉起..." >> "${ET_DIR}/watchdog.log"
     systemctl restart "${service_name}"
  fi
}

# 创建看门狗的 Timer 和 Service
create_watchdog_systemd() {
  local net_name="$1"
  local wd_service="easytier-wd-${net_name}.service"
  local wd_timer="easytier-wd-${net_name}.timer"
  
  # 确保全局命令存在，因为 Watchdog 需要调用它
  install_self_global >/dev/null 2>&1

  # 1. 定义执行检测的服务
  cat > "${SYSTEMD_DIR}/${wd_service}" <<EOF
[Unit]
Description=EasyTier Watchdog Check for ${net_name}
[Service]
Type=oneshot
ExecStart=/usr/local/bin/${GLOBAL_BIN_NAME} watchdog-check ${net_name}
EOF

  # 2. 定义定时器 (每1分钟检测一次)
  cat > "${SYSTEMD_DIR}/${wd_timer}" <<EOF
[Unit]
Description=Run EasyTier Watchdog every 1 minute for ${net_name}
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${wd_timer}"
  echo -e "${GREEN}Watchdog (看门狗) 已配置: ${net_name} (每60秒检测一次状态)${NC}"
}

remove_watchdog_systemd() {
  local net_name="$1"
  systemctl disable --now "easytier-wd-${net_name}.timer" 2>/dev/null || true
  rm -f "${SYSTEMD_DIR}/easytier-wd-${net_name}.timer"
  rm -f "${SYSTEMD_DIR}/easytier-wd-${net_name}.service"
}

# ================= 服务管理逻辑 =================

create_service_file() {
  local net_name="$1"
  local cmd_args="$2"
  local service_name="easytier-${net_name}.service"
  local service_path="${SYSTEMD_DIR}/${service_name}"

  [ -z "${net_name}" ] && return 1

  # 停止旧服务
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
# 标准输出日志，方便 journalctl 查看
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  if systemctl enable --now "${service_name}"; then
    echo -e "${GREEN}网络服务 [${net_name}] 已启动${NC}"
    # == 自动添加 Watchdog ==
    create_watchdog_systemd "${net_name}"
    return 0
  else
    echo -e "${RED}服务启动失败，请检查: systemctl status ${service_name}${NC}"
    rm -f "${service_path}"
    return 1
  fi
}

delete_network_by_name() {
  local d_name="$1"
  local service_name="easytier-${d_name}.service"
  local service_path="${SYSTEMD_DIR}/${service_name}"

  if [ ! -f "${service_path}" ]; then
    echo -e "${RED}未找到网络: ${d_name}${NC}"
    return 1
  fi

  # 移除 Watchdog
  remove_watchdog_systemd "${d_name}"

  systemctl stop "${service_name}" 2>/dev/null || true
  systemctl disable "${service_name}" 2>/dev/null || true
  rm -f "${service_path}"
  systemctl daemon-reload
  echo -e "${GREEN}网络 [${d_name}] 已删除${NC}"
}

# ================= 业务功能逻辑 =================

# 追加子网代理 (Subnet Proxy)
add_subnet_proxy_logic() {
    list_networks
    echo -e "\n${BLUE}>>> 追加子网代理 (暴露本机网络)${NC}"
    read -rp "请输入要配置的网络名称: " t_net_name
    
    local service_path="${SYSTEMD_DIR}/easytier-${t_net_name}.service"
    if [ ! -f "${service_path}" ]; then
        echo -e "${RED}错误：找不到网络 [${t_net_name}]${NC}"
        return 1
    fi

    # 检查是否已经配置过
    if grep -q "\-n " "${service_path}" || grep -q "\-\-network-cidr" "${service_path}"; then
        echo -e "${YELLOW}警告：该网络似乎已经配置过子网代理，继续操作将追加配置。${NC}"
    fi

    echo -e "请输入要暴露的网段 (CIDR格式，例如 192.168.1.0/24)"
    read -rp "CIDR: " t_cidr
    
    if [[ ! "${t_cidr}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        echo -e "${RED}格式错误，请输入标准的 CIDR 格式。${NC}"
        return 1
    fi

    # 使用 sed 修改 ExecStart 行
    # 逻辑：匹配 ExecStart=... 行，在末尾添加 -n CIDR
    sed -i "/^ExecStart=/ s/$/ -n ${t_cidr//\//\\/}/" "${service_path}"

    echo -e "${YELLOW}正在重载服务 [${t_net_name}]...${NC}"
    systemctl daemon-reload
    systemctl restart "easytier-${t_net_name}.service"
    
    if systemctl is-active --quiet "easytier-${t_net_name}.service"; then
        echo -e "${GREEN}成功！已向 [${t_net_name}] 追加代理网段: ${t_cidr}${NC}"
    else
        echo -e "${RED}服务重启失败，请检查配置。${NC}"
        systemctl status "easytier-${t_net_name}.service" --no-pager
    fi
}

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
    
    if ! [[ "${p_my_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo -e "${RED}错误：虚拟 IP 格式不正确 (${p_my_ip})${NC}"
      return 1
    fi

    CMD_ARGS="-i ${p_my_ip} --network-name ${p_net_name} --network-secret ${p_secret} ${listener_arg}"
    create_service_file "${p_net_name}" "${CMD_ARGS}"

    echo -e "${YELLOW}正在获取公网 IP...${NC}"
    PUBLIC_IP="$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com 2>/dev/null || echo 'YOUR_PUBLIC_IP')"
    CLIENT_SUGGEST_IP=$(get_next_ip "${p_my_ip}")
    JOIN_CMD="curl -sSL ${SCRIPT_RAW_URL} -o /tmp/et.sh && chmod +x /tmp/et.sh && bash /tmp/et.sh conn-ip=${PUBLIC_IP}:${local_port} my-ip=${CLIENT_SUGGEST_IP} net-name=${p_net_name} secret=${p_secret}"

    echo -e "\n${GREEN}========== 网络创建成功 ==========${NC}"
    echo -e "网络名称 : ${YELLOW}${p_net_name}${NC}"
    echo -e "本机 IP  : ${YELLOW}${p_my_ip}${NC}"
    echo -e "密钥     : ${YELLOW}${p_secret}${NC}"
    echo -e "Watchdog : ${GREEN}已启用 (检测间隔 60s)${NC}"
    echo -e "\n${BLUE}客户端一键加入命令:${NC}"
    echo -e "${YELLOW}${JOIN_CMD}${NC}"

  # --- Client 模式 (加入网络) ---
  else
    PEER_URL="${p_conn_ip}"
    if [[ "${PEER_URL}" != *:* ]]; then
        PEER_URL="tcp://${PEER_URL}:11010"
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
    echo -e "Watchdog : ${GREEN}已启用 (检测间隔 60s)${NC}"
  fi
}

list_networks() {
  echo -e "\n${BLUE}=== 已配置的网络 ===${NC}"
  local services
  services=$(ls "${SYSTEMD_DIR}"/easytier-*.service 2>/dev/null | grep -v "easytier-wd-" || true)
  
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

    # 检查 Watchdog 状态
    if systemctl is-active --quiet "easytier-wd-${net_name}.timer"; then
        wd_status="${GREEN}护卫中${NC}"
    else
        wd_status="${YELLOW}无${NC}"
    fi
    
    # 检查是否开启了代理
    if grep -q "\-n " "${svc}"; then
        proxy_info="[代理开启]"
    else
        proxy_info=""
    fi

    ip=$(_extract_ip_from_service "${svc}")
    echo -e "网络: ${YELLOW}${net_name}${NC} | 状态: ${status} | 狗: ${wd_status} | IP: ${BLUE}${ip}${NC} ${proxy_info}"
  done <<< "${services}"
}

# ================= 入口逻辑 =================
install_easytier || true

# 参数解析
P_CONN=""
P_MY=""
P_NAME=""
P_SEC=""
P_DEL=""
HAS_ARGS=false

# 内部调用逻辑处理
if [ "$1" == "watchdog-check" ]; then
    watchdog_check "$2"
    exit 0
fi

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
    esac
  else
    case "$arg" in
      install)   install_self_global; exit 0 ;;
      uninstall) uninstall_self_global; exit 0 ;;
      list)      list_networks; exit 0 ;;
      add-proxy) add_subnet_proxy_logic; exit 0 ;; # 命令行入口
      delete)    
        list_networks
        read -rp "请输入要删除的网络名称: " d_n
        [ -n "$d_n" ] && delete_network_by_name "$d_n"
        exit 0 
        ;;
    esac
  fi
done

if [ "$HAS_ARGS" = true ]; then
  run_add_logic "${P_CONN}" "${P_MY}" "${P_NAME}" "${P_SEC}"
  exit $?
fi

# 交互式菜单
while true; do
  echo -e "\n${BLUE}=== EasyTier 网络管理工具 (v2.6) ===${NC}"
  echo "1. 创建网络 (Host模式)"
  echo "2. 加入网络 (Client模式)"
  echo "3. 查看网络状态"
  echo "4. 删除网络"
  echo "5. 安装到系统命令"
  echo "6. 追加子网代理 (暴露内网)"
  echo "0. 退出"
  
  read -rp "请选择 [0-6]: " choice
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
    6) add_subnet_proxy_logic ;;
    0) exit 0 ;;
    *) echo -e "${RED}输入无效${NC}" ;;
  esac
done