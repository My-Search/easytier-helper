#!/bin/bash
# EasyTier 管理脚本 (v2.6)
# Feat:
# - 自动为每个网络添加 Watchdog（异常自动重启）
# - 支持向已有网络追加暴露本机子网（子网代理）

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
WATCHDOG_INTERVAL=15
# =========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

[ "$EUID" -ne 0 ] && { echo -e "${RED}请使用 root 运行${NC}"; exit 1; }

_required_cmds=(wget unzip systemctl curl awk sed grep)
for c in "${_required_cmds[@]}"; do
  command -v "$c" >/dev/null || echo -e "${YELLOW}缺少命令 $c${NC}"
done

# ================= 工具函数 =================

get_next_ip() { echo "$1" | awk -F. '{$NF+=1}1' OFS=.; }

get_random_port() { shuf -i 11011-11999 -n 1 2>/dev/null || echo $((11011+RANDOM%800)); }

install_easytier() {
  [ -x "${ET_DIR}/easytier-core" ] && return
  tmp=$(mktemp -d)
  wget -q -O "$tmp/et.zip" "https://github.com/EasyTier/EasyTier/releases/download/${ET_VERSION}/easytier-linux-x86_64-${ET_VERSION}.zip"
  unzip -q "$tmp/et.zip" -d "$tmp"
  mkdir -p "$ET_DIR"
  mv "$tmp"/**/easytier-core "$ET_DIR/"
  chmod +x "$ET_DIR/easytier-core"
  rm -rf "$tmp"
}

install_self_global() {
  cp -f "$0" "/usr/local/bin/${GLOBAL_BIN_NAME}"
  chmod +x "/usr/local/bin/${GLOBAL_BIN_NAME}"
}

# ================= Watchdog =================

create_watchdog() {
  local net="$1"
  local svc="easytier-${net}.service"
  local wd="easytier-${net}-watchdog.service"

  cat >"${SYSTEMD_DIR}/${wd}" <<EOF
[Unit]
Description=EasyTier Watchdog (${net})
After=${svc}

[Service]
Type=simple
ExecStart=/bin/bash -c '
while true; do
  if ! ${ET_DIR}/easytier-core status --network-name ${net} 2>/dev/null | grep -q "Connected"; then
    systemctl restart ${svc}
  fi
  sleep ${WATCHDOG_INTERVAL}
done
'
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${wd}"
}

remove_watchdog() {
  local net="$1"
  systemctl disable --now "easytier-${net}-watchdog.service" 2>/dev/null || true
  rm -f "${SYSTEMD_DIR}/easytier-${net}-watchdog.service"
}

# ================= Service =================

create_service_file() {
  local net="$1"
  local args="$2"
  local svc="${SYSTEMD_DIR}/easytier-${net}.service"

  cat >"$svc" <<EOF
[Unit]
Description=EasyTier ${net}
After=network-online.target

[Service]
ExecStart=${ET_DIR}/easytier-core ${args}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "easytier-${net}.service"
  create_watchdog "$net"
}

# ================= 子网代理 =================

expose_subnet() {
  list_networks
  read -rp "选择网络名称: " net
  local svc="${SYSTEMD_DIR}/easytier-${net}.service"
  [ ! -f "$svc" ] && { echo -e "${RED}网络不存在${NC}"; return; }

  read -rp "输入要暴露的子网 (CIDR，如 192.168.1.0/24): " cidr
  grep -q -- "--subnet-proxy ${cidr}" "$svc" && { echo "已存在"; return; }

  sed -i "s|ExecStart=.*|& --subnet-proxy ${cidr}|" "$svc"
  systemctl daemon-reload
  systemctl restart "easytier-${net}.service"
}

# ================= 网络 =================

list_networks() {
  echo -e "${BLUE}=== 网络列表 ===${NC}"
  for f in ${SYSTEMD_DIR}/easytier-*.service; do
    [ -e "$f" ] || continue
    n=$(basename "$f" | sed 's/easytier-\(.*\)\.service/\1/')
    systemctl is-active --quiet "easytier-${n}.service" && s="${GREEN}运行${NC}" || s="${RED}停止${NC}"
    echo -e "$n | $s"
  done
}

delete_network_by_name() {
  local n="$1"
  systemctl disable --now "easytier-${n}.service" 2>/dev/null || true
  remove_watchdog "$n"
  rm -f "${SYSTEMD_DIR}/easytier-${n}.service"
  systemctl daemon-reload
}

run_add_logic() {
  local conn="$1" ip="$2" net="$3" sec="$4"
  port=$(get_random_port)
  listen="--listeners tcp://0.0.0.0:${port}"

  if [ -z "$conn" ]; then
    args="-i ${ip} --network-name ${net} --network-secret ${sec} ${listen}"
  else
    args="-p tcp://${conn} -i ${ip} --network-name ${net} --network-secret ${sec} ${listen}"
  fi
  create_service_file "$net" "$args"
}

# ================= 入口 =================

install_easytier

while true; do
  echo -e "\n${BLUE}EasyTier 管理${NC}"
  echo "1. 创建网络"
  echo "2. 加入网络"
  echo "3. 查看网络"
  echo "4. 删除网络"
  echo "5. 暴露子网"
  echo "0. 退出"
  read -rp "选择: " c
  case "$c" in
    1)
      read -rp "网络名: " n
      read -rp "密钥: " s
      read -rp "本机IP: " ip
      run_add_logic "" "$ip" "$n" "$s"
      ;;
    2)
      read -rp "主机IP:PORT: " p
      read -rp "网络名: " n
      read -rp "密钥: " s
      read -rp "本机IP: " ip
      run_add_logic "$p" "$ip" "$n" "$s"
      ;;
    3) list_networks ;;
    4)
      list_networks
      read -rp "删除网络名: " n
      delete_network_by_name "$n"
      ;;
    5) expose_subnet ;;
    0) exit ;;
  esac
done
