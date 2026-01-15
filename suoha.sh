#!/bin/bash
# ====================================================
# 一键梭哈脚本 · 2026 Final v3.1 · TEST-STABLE
# 固定隧道 + 临时隧道 + 多语言 + systemd 自启（方案 A）
# ====================================================

set -euo pipefail

BASE_DIR="${HOME}/.suoha"
XRAY_BIN="$BASE_DIR/xray"
ARGO_BIN="$BASE_DIR/cloudflared"
CONFIG_FILE="$BASE_DIR/config.json"
TUNNEL_CONFIG="$BASE_DIR/config.yaml"
LOG_DIR="$BASE_DIR/logs"
XRAY_LOG="$LOG_DIR/xray.log"
ARGO_LOG="$LOG_DIR/argo.log"
LANG_FILE="$BASE_DIR/language"

mkdir -p "$BASE_DIR" "$LOG_DIR"

# ---------------- 多语言 ----------------
declare -A zh=(
  [welcome]="===== 一键梭哈 (2026 v3.1) ====="
  [choose]="1) 临时隧道\n2) 固定隧道 (域名 + 自启)\n3) 清理进程\n0) 退出"
  [lang_prompt]="请选择语言 (1=中文 / 2=English): "
  [fixed_need]="需要 Cloudflare 托管域名 + 账号"
  [fixed_domain]="输入完整域名 (如 sub.example.com): "
  [fixed_success]="固定隧道已启动，自启已配置"
  [links_saved]="节点已保存到"
)

declare -A en=(
  [welcome]="===== Suoha One-Click (2026 v3.1) ====="
  [choose]="1) Temporary Tunnel\n2) Fixed Tunnel (domain + auto-start)\n3) Cleanup\n0) Exit"
  [lang_prompt]="Select language (1=Chinese / 2=English): "
  [fixed_need]="Requires Cloudflare managed domain"
  [fixed_domain]="Enter full domain (sub.example.com): "
  [fixed_success]="Fixed tunnel running, auto-start configured"
  [links_saved]="Nodes saved to"
)

# ---------------- 语言选择 ----------------
if [[ ! -f "$LANG_FILE" ]]; then
  echo "${zh[lang_prompt]}${en[lang_prompt]}"
  read -p "> " l
  [[ "$l" == "1" ]] && echo zh >"$LANG_FILE" || echo en >"$LANG_FILE"
fi
LANGUAGE=$(cat "$LANG_FILE")
t(){ eval "echo \${${LANGUAGE}[$1]}"; }

green(){ echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }

# ---------------- ISP ----------------
get_isp(){
  curl -4 -s https://speed.cloudflare.com/meta \
  | jq -r '"\(.city)-\(.colo)-\(.asn)"' 2>/dev/null \
  | tr ' ' '_' || echo "unknown"
}

# ---------------- 依赖 ----------------
install_deps(){
  command -v curl unzip jq >/dev/null && return
  yellow "Installing dependencies..."
  if grep -qi alpine /etc/os-release; then
    apk add curl unzip jq bash
  elif command -v apt >/dev/null; then
    apt update && apt install -y curl unzip jq
  elif command -v dnf >/dev/null; then
    dnf install -y curl unzip jq
  else
    red "Unsupported package manager"
    exit 1
  fi
}

# ---------------- 下载核心 ----------------
download_bins(){
  [[ -x "$XRAY_BIN" && -x "$ARGO_BIN" ]] && return
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64) xrayf="Xray-linux-64.zip"; cfarch="amd64" ;;
    aarch64|arm64) xrayf="Xray-linux-arm64-v8a.zip"; cfarch="arm64" ;;
    *) red "Unsupported arch"; exit 1 ;;
  esac

  curl -L https://github.com/XTLS/Xray-core/releases/latest/download/$xrayf -o x.zip
  unzip -o x.zip xray -d "$BASE_DIR"
  chmod +x "$XRAY_BIN"
  rm -f x.zip

  curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cfarch -o "$ARGO_BIN"
  chmod +x "$ARGO_BIN"
}

# ---------------- 生成配置 ----------------
generate_xray_config(){
  UUID=$(
    cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || uuidgen 2>/dev/null \
    || echo "$(date +%s)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' ')"
  )
  PORT=$((RANDOM+10000))
  WS_PATH="/suoha-$(od -An -N4 -tx1 /dev/urandom | tr -d ' ')"

cat >"$CONFIG_FILE"<<EOF
{
 "inbounds":[{
   "port":$PORT,
   "listen":"127.0.0.1",
   "protocol":"vmess",
   "settings":{"clients":[{"id":"$UUID","alterId":0}]},
   "streamSettings":{"network":"ws","wsSettings":{"path":"$WS_PATH"}}
 }],
 "outbounds":[{"protocol":"freedom"}]
}
EOF
  echo "$UUID $WS_PATH $PORT"
}

# ---------------- 节点 ----------------
show_links(){
  local domain="$1" uuid="$2" path="$3" isp="$4" mode="$5"
  file="$BASE_DIR/nodes_${mode}.txt"
cat >"$file"<<EOF
vmess://$(echo -n "{\"v\":\"2\",\"ps\":\"Suoha_${mode}_$isp\",\"add\":\"cloudflare.518920.xyz\",\"port\":\"443\",\"id\":\"$uuid\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$domain\",\"path\":\"$path\",\"tls\":\"tls\"}" | base64 -w0)
EOF
  green "$(t links_saved) $file"
  cat "$file"
}

# ---------------- 临时隧道 ----------------
quick_tunnel(){
  download_bins
  read UUID WS_PATH PORT <<<"$(generate_xray_config)"
  ISP=$(get_isp)

  nohup "$XRAY_BIN" run -c "$CONFIG_FILE" >"$XRAY_LOG" 2>&1 &
  nohup "$ARGO_BIN" tunnel --url http://127.0.0.1:$PORT >"$ARGO_LOG" 2>&1 &

  for _ in {1..30}; do
    DOMAIN=$(grep -oE 'https://[-a-z0-9]+\.trycloudflare\.com' "$ARGO_LOG" | head -1 || true)
    [[ -n "$DOMAIN" ]] && break
    sleep 1
  done

  DOMAIN="${DOMAIN#https://}"
  show_links "$DOMAIN" "$UUID" "$WS_PATH" "$ISP" "Quick"
}

# ---------------- 固定隧道 ----------------
fixed_tunnel(){
  yellow "$(t fixed_need)"
  download_bins
  read UUID WS_PATH PORT <<<"$(generate_xray_config)"
  ISP=$(get_isp)

  "$ARGO_BIN" tunnel login
  read -p "$(t fixed_domain)" FULL_DOMAIN
  TUNNEL_NAME="${FULL_DOMAIN%%.*}"

  "$ARGO_BIN" tunnel create "$TUNNEL_NAME" || true
  "$ARGO_BIN" tunnel route dns "$TUNNEL_NAME" "$FULL_DOMAIN"

  CREDS_FILE=$(grep -l "\"TunnelName\": \"$TUNNEL_NAME\"" ~/.cloudflared/*.json 2>/dev/null | head -1)
  [[ -z "$CREDS_FILE" ]] && { red "Credentials not found"; exit 1; }

cat >"$TUNNEL_CONFIG"<<EOF
tunnel: $TUNNEL_NAME
credentials-file: $CREDS_FILE
ingress:
  - hostname: $FULL_DOMAIN
    service: http://localhost:$PORT
  - service: http_status:404
EOF

  nohup "$XRAY_BIN" run -c "$CONFIG_FILE" >"$XRAY_LOG" 2>&1 &
  nohup "$ARGO_BIN" tunnel --config "$TUNNEL_CONFIG" run "$TUNNEL_NAME" >"$ARGO_LOG" 2>&1 &

  setup_autostart "$TUNNEL_NAME"

  show_links "$FULL_DOMAIN" "$UUID" "$WS_PATH" "$ISP" "Fixed"
  green "$(t fixed_success)"
}

# ---------------- systemd 自启（方案 A） ----------------
setup_autostart(){
  [[ $EUID -ne 0 ]] && { yellow "非 root，跳过自启"; return; }
  command -v systemctl >/dev/null || { yellow "No systemd"; return; }

cat >/etc/systemd/system/suoha-xray.service<<EOF
[Unit]
Description=Suoha Xray
After=network.target

[Service]
ExecStart=$XRAY_BIN run -c $CONFIG_FILE
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/suoha-argo.service<<EOF
[Unit]
Description=Suoha Cloudflared
After=network.target

[Service]
ExecStart=$ARGO_BIN tunnel --config $TUNNEL_CONFIG run $1
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now suoha-xray suoha-argo
}

# ---------------- 清理 ----------------
cleanup(){
  pkill -f xray 2>/dev/null || true
  pkill -f cloudflared 2>/dev/null || true
  yellow "进程已清理"
}

# ---------------- 菜单 ----------------
clear
install_deps
green "$(t welcome)"
echo "$(t choose)"
read -p "> " c
case "$c" in
  1) quick_tunnel ;;
  2) fixed_tunnel ;;
  3) cleanup ;;
  0) exit 0 ;;
esac