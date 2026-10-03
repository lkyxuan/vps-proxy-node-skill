#!/bin/bash
# ============================================================
#  订阅链接服务:在 VPS 上用 Caddy(Docker)发布 HTTPS 订阅,客户端贴 URL 即可导入
#
#  - 域名:<IP 用横杠>.sslip.io(免费通配 DNS,直接解析到本机 IP),无需买域名
#  - 证书:Caddy 自动申请 Let's Encrypt(HTTP-01,需要 80/tcp 可达)
#  - 路径:/<随机 token>/...,只认 token,根路径和目录都 404
#
#  前提:同目录有 gen-clients.sh;已装 Docker(setup.sh 会装)
#  用法(服务器上 root 运行,幂等;重跑会保留 token 并刷新节点内容):
#    NAME_PREFIX=FRA SUB_PORT=8880 bash sub-server.sh
#  换 token(旧链接立即失效): ROTATE_TOKEN=yes bash sub-server.sh
#  卸载: docker rm -f sub-caddy && rm -rf /opt/sub
# ============================================================
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "必须 root 运行"; exit 1; }
command -v docker >/dev/null || { echo "需要 Docker"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${NAME_PREFIX:-NODE}"
SUB_PORT="${SUB_PORT:-8880}"
BASE=/opt/sub

IP=$(curl -4 -s --max-time 8 https://api.ipify.org)
DOMAIN="${SUB_DOMAIN:-${IP//./-}.sslip.io}"

install -d -m 700 "$BASE"
if [ ! -s "$BASE/token" ] || [ "${ROTATE_TOKEN:-no}" = "yes" ]; then
  openssl rand -hex 16 > "$BASE/token"
fi
TOKEN=$(cat "$BASE/token")

# 1) 生成三端配置
NAME_PREFIX="$PREFIX" bash "$HERE/gen-clients.sh" >/dev/null
SRC=/root/clients

# 2) 组装订阅文件
rm -rf "$BASE/www"; install -d "$BASE/www/$TOKEN"
W="$BASE/www/$TOKEN"
base64 -w0 "$SRC/shadowrocket.txt" > "$W/shadowrocket"                          # 小火箭:base64 订阅
sed -n '/^\[Proxy\]/,/^\[/{/^\[/d;/^$/d;p}' "$SRC/surge.conf" > "$W/surge.list"  # Surge:policy-path 节点列表
GROUP="自建-$PREFIX"
{ # OpenClash:完整可用的 Mihomo 配置(也可当 proxy-provider 用,只读 proxies)
  cat <<EOF
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
EOF
  sed -n '/^proxies:/,$p' "$SRC/openclash.yaml"
  cat <<EOF

rules:
  - GEOIP,LAN,DIRECT,no-resolve
  - GEOSITE,CN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,$GROUP
EOF
} > "$W/clash.yaml"
rm -rf "$SRC"
chmod -R a+rX "$BASE/www"

# 3) Caddy
cat > "$BASE/Caddyfile" <<EOF
$DOMAIN:$SUB_PORT {
  @ok path /$TOKEN/shadowrocket /$TOKEN/surge.list /$TOKEN/clash.yaml
  handle @ok {
    root * /srv
    header Cache-Control "no-store"
    header Content-Type "text/plain; charset=utf-8"
    file_server
  }
  handle {
    respond 404
  }
}
EOF
if docker ps -a --format '{{.Names}}' | grep -qx sub-caddy; then
  docker exec sub-caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || docker restart sub-caddy >/dev/null
else
  docker run -d --name sub-caddy --restart unless-stopped --network host \
    -v "$BASE/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$BASE/www:/srv:ro" \
    -v sub-caddy-data:/data -v sub-caddy-config:/config caddy:2-alpine >/dev/null
fi

U="https://$DOMAIN:$SUB_PORT/$TOKEN"
echo "等待证书签发..."
for i in $(seq 1 30); do curl -sf --max-time 5 -o /dev/null "$U/surge.list" && break; sleep 3; done
curl -sf --max-time 5 -o /dev/null "$U/surge.list" && echo "✓ HTTPS 订阅可用" || echo "✗ 还不通:docker logs sub-caddy 看原因(80/tcp 和 $SUB_PORT/tcp 要放行)"
cat <<EOF

小火箭订阅:   $U/shadowrocket
Surge 节点:   $U/surge.list     (用法: 自建 = select, policy-path=$U/surge.list)
OpenClash:    $U/clash.yaml
⚠️ 拿到链接 = 拿到节点,别外传;泄露了就 ROTATE_TOKEN=yes 重跑
EOF
