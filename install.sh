#!/usr/bin/env bash
# ============================================================
#  sing-box AnyTLS 一键部署脚本
#  作者 Hermes 对接 mimo-v2.5-pro
#  https://zelikk.blogspot.com/2026/06/sing-box-anytls.html
#  用法:
#    bash install.sh                          # 全部使用默认值
#    PORT=443 SNI=example.com bash install.sh # 自定义参数
# ============================================================
set -euo pipefail

# ── 可配置参数（环境变量优先） ──────────────────────────
PORT="${PORT:-2083}"
SNI="${SNI:-learn.microsoft.com}"
PASSWORD="${PASSWORD:-$(openssl rand -base64 16)}"
BIND_ADDR="${BIND_ADDR:-::}"
CERT_DAYS="${CERT_DAYS:-3650}"
CERT_DIR="${CERT_DIR:-/etc/sing-box/cert}"
CONFIG_PATH="${CONFIG_PATH:-/etc/sing-box/config.json}"

# ── 颜色 ────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; R='\033[0m'
info()  { printf "${G}[✓]${R} %s\n" "$*"; }
warn()  { printf "${Y}[!]${R} %s\n" "$*"; }
step()  { printf "\n${C}── %s ──${R}\n" "$*"; }

# ── 0. 前置检查 ──────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "请以 root 身份运行此脚本"; exit 1
fi

# ── 1. 安装 sing-box（官方脚本）──────────────────────────
step "安装 sing-box"

if command -v sing-box &>/dev/null; then
  CURRENT_VER=$(sing-box version 2>/dev/null | head -1 | awk '{print $3}')
  info "已安装 sing-box ${CURRENT_VER}，跳过安装"
else
  info "通过官方脚本安装 sing-box ..."
  curl -fsSL https://sing-box.app/install.sh | sh
  info "sing-box $(sing-box version | head -1) 已安装"
fi

# ── 2. 生成自签证书 ──────────────────────────────────────
step "生成自签证书 (${SNI})"

mkdir -p "$CERT_DIR"
openssl req -x509 -nodes \
  -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -days "$CERT_DAYS" \
  -keyout "${CERT_DIR}/key.pem" \
  -out "${CERT_DIR}/cert.pem" \
  -subj "/CN=${SNI}" \
  -addext "subjectAltName=DNS:${SNI}" \
  2>/dev/null

EXPIRE=$(openssl x509 -in "${CERT_DIR}/cert.pem" -noout -enddate | cut -d= -f2)
info "证书已生成，有效期至 ${EXPIRE}"

# 官方 deb 包以 sing-box 用户运行，需确保证书可读
if id sing-box &>/dev/null; then
  chown -R sing-box:sing-box "$CERT_DIR"
  info "已设置证书目录归属为 sing-box 用户"
fi

# ── 3. 写入配置 ──────────────────────────────────────────
step "写入 sing-box 配置"

mkdir -p "$(dirname "$CONFIG_PATH")"
cat > "$CONFIG_PATH" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "${BIND_ADDR}",
      "listen_port": ${PORT},
      "users": [
        { "name": "user1", "password": "${PASSWORD}" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "certificate_path": "${CERT_DIR}/cert.pem",
        "key_path": "${CERT_DIR}/key.pem"
      }
    }
  ],
  "outbounds": [ { "type": "direct" } ]
}
EOF
info "配置已写入 ${CONFIG_PATH}"

# ── 4. 验证配置 ──────────────────────────────────────────
step "验证配置"
sing-box check -c "$CONFIG_PATH"
info "配置校验通过"

# ── 5. 启动服务 ──────────────────────────────────────────
step "启动 sing-box 服务"

# 官方安装脚本已创建 systemd service，只需重载并启动
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box
sleep 1

if systemctl is-active --quiet sing-box; then
  info "sing-box 服务已启动"
else
  echo "启动失败，查看日志:"; journalctl -u sing-box --no-pager -n 20; exit 1
fi

# ── 6. 输出连接信息 ──────────────────────────────────────
step "部署完成"

# 通过物理网口 + Cloudflare trace 获取公网 IPv4
Public_IPv4=""
InFaces=($(ls /sys/class/net/ | grep -E '^(eth|ens|eno|esp|enp|venet|vif)'))
for i in "${InFaces[@]}"; do
  ip=$(curl -4s --interface "$i" -m 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -oP "ip=\K.*$")
  if [[ -n "$ip" ]]; then
    Public_IPv4="$ip"
    break
  fi
done
SERVER_IP="${Public_IPv4:-$(hostname -I | awk '{print $1}')}"

# URL-encode 密码中的特殊字符
ENCODED_PW=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${PASSWORD}', safe=''))" 2>/dev/null \
  || echo "${PASSWORD//==/%3D%3D}")

URI="anytls://${ENCODED_PW}@${SERVER_IP}:${PORT}/?sni=${SNI}&insecure=1"

echo ""
echo "┌─────────────────────────────────────────────────────"
echo "│  AnyTLS 节点信息"
echo "├─────────────────────────────────────────────────────"
echo "│  服务器    : ${SERVER_IP}"
echo "│  端口      : ${PORT}"
echo "│  SNI       : ${SNI}"
echo "│  用户名    : user1"
echo "│  密码      : ${PASSWORD}"
echo "│  证书      : 自签 (insecure)"
echo "├─────────────────────────────────────────────────────"
echo "│  URI 分享链接:"
echo "│  ${URI}"
echo "├─────────────────────────────────────────────────────"
echo "│  sing-box 客户端配置:"
echo "│"
echo "│  {"
echo "│    \"type\": \"anytls\","
echo "│    \"tag\": \"proxy\","
echo "│    \"server\": \"${SERVER_IP}\","
echo "│    \"server_port\": ${PORT},"
echo "│    \"password\": \"${PASSWORD}\","
echo "│    \"tls\": {"
echo "│      \"enabled\": true,"
echo "│      \"server_name\": \"${SNI}\","
echo "│      \"insecure\": true"
echo "│    }"
echo "│  }"
echo "└─────────────────────────────────────────────────────"
